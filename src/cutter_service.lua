--------------------------------------------------
-- Domain Service: CutterService (FFmpeg)
--------------------------------------------------
local Platform = require("platform")

local CutterService = {}

--- Sanitize scene title for filesystem output
function CutterService.sanitize_filename(name)
    if not name or name == "" then return "scene" end
    -- Replace characters illegal in Windows/Linux file paths
    local clean = name:gsub('[\\/:*?"<>|]', "_"):gsub("%s+", "_")
    clean = clean:gsub("^_+", ""):gsub("_+$", "")
    return clean ~= "" and clean or "scene"
end

--- Derive output fragment filename from video path, scene, and optional working directory
function CutterService.derive_output_path(video_path, scene, work_dir)
    local dir, filename = video_path:match("^(.-)([^\\/]+)$")
    if not dir then
        dir = ""
        filename = video_path
    end

    local stem, ext = filename:match("^(.*)%.([^%.\\/]+)$")
    if not stem then
        stem = filename
        ext = "mp4"
    end

    local clean_title = CutterService.sanitize_filename(scene.title)
    local out_name = string.format("%s_scene_%02d_%s.%s", stem, scene.id, clean_title, ext)

    if work_dir and work_dir:match("%S") then
        work_dir = work_dir:match("^%s*(.-)%s*$")
        local sep = (work_dir:find("\\") or Platform.is_windows) and "\\" or "/"
        if not work_dir:match("[\\/]$") then
            work_dir = work_dir .. sep
        end
        return work_dir .. out_name
    end

    return dir .. out_name
end

--- Discover available FFmpeg executable path
-- @param is_win boolean Optional override for testing
-- @return string Path or command name to invoke FFmpeg
function CutterService.find_ffmpeg(is_win)
    if is_win == nil then is_win = Platform.is_windows end

    if is_win then
        -- Check dedicated VLC tools directory and extension folder in AppData
        local appdata = os.getenv("APPDATA")
        if appdata then
            local p_bin = appdata .. "\\vlc\\bin\\ffmpeg.exe"
            local f_bin = io.open(p_bin, "r")
            if f_bin then f_bin:close(); return p_bin end

            local p_ext = appdata .. "\\vlc\\lua\\extensions\\ffmpeg.exe"
            local f_ext = io.open(p_ext, "r")
            if f_ext then f_ext:close(); return p_ext end

            local p_vlc = appdata .. "\\vlc\\ffmpeg.exe"
            local f_vlc = io.open(p_vlc, "r")
            if f_vlc then f_vlc:close(); return p_vlc end
        end

        -- Check WinGet standard package link
        local localappdata = os.getenv("LOCALAPPDATA")
        if localappdata then
            local p = localappdata .. "\\Microsoft\\WinGet\\Links\\ffmpeg.exe"
            local f = io.open(p, "r")
            if f then f:close(); return p end
        end

        -- Check standard root installation
        local p_root = "C:\\ffmpeg\\bin\\ffmpeg.exe"
        local f_root = io.open(p_root, "r")
        if f_root then f_root:close(); return p_root end

        -- Check all directories in Windows %PATH% via pure file I/O (0 processes, 0 console windows)
        local path_env = os.getenv("PATH")
        if path_env then
            for dir in path_env:gmatch("[^;]+") do
                dir = dir:match("^%s*(.-)%s*$")
                if dir ~= "" then
                    local p = dir:gsub("[\\/]+$", "") .. "\\ffmpeg.exe"
                    local f = io.open(p, "r")
                    if f then f:close(); return p end
                end
            end
        end

        return "ffmpeg.exe"
    else
        -- Check Snap VLC common bin (shared across snap revisions)
        local snap_common = os.getenv("SNAP_USER_COMMON")
        if snap_common then
            local p = snap_common .. "/bin/ffmpeg"
            local f = io.open(p, "r")
            if f then f:close(); return p end
        end

        local home = os.getenv("HOME")
        if home then
            local snap_bin = home .. "/snap/vlc/common/bin/ffmpeg"
            local f = io.open(snap_bin, "r")
            if f then f:close(); return snap_bin end

            local local_bin = home .. "/.local/bin/ffmpeg"
            local f2 = io.open(local_bin, "r")
            if f2 then f2:close(); return local_bin end
        end

        local f_usr = io.open("/usr/bin/ffmpeg", "r")
        if f_usr then f_usr:close(); return "/usr/bin/ffmpeg" end

        -- Check all directories in POSIX PATH via pure file I/O
        local path_env = os.getenv("PATH")
        if path_env then
            for dir in path_env:gmatch("[^:]+") do
                dir = dir:match("^%s*(.-)%s*$")
                if dir ~= "" then
                    local p = dir:gsub("/+$", "") .. "/ffmpeg"
                    local f = io.open(p, "r")
                    if f then f:close(); return p end
                end
            end
        end

        return "ffmpeg"
    end
end

--- Verify that FFmpeg is accessible and executable
-- @param is_win boolean Optional override for testing
-- @return boolean, string ok, binary_or_error
function CutterService.check_ffmpeg(is_win)
    if is_win == nil then is_win = Platform.is_windows end
    local bin = CutterService.find_ffmpeg(is_win)

    -- Fast-path: if binary is an absolute path (already checked via io.open in find_ffmpeg), it exists on disk
    if Platform.is_absolute(bin, is_win) then
        local f = io.open(bin, "r")
        if f then
            f:close()
            return true, bin
        end
    end

    if is_win then
        -- On Windows, all known locations and PATH directories have already been checked via pure io.open.
        -- Spawning a console probe would needlessly flash CMD windows.
        return false, "FFmpeg was not found in PATH or %APPDATA%\\vlc\\bin\\. Run install-ffmpeg-windows.bat or click 'Export Cut Script'."
    else
        -- Test executing binary with -version on POSIX
        local probe_cmd = Platform.quote(bin, false) .. " -nostdin -version > /dev/null 2>&1"
        if os and os.execute then
            local code = os.execute(probe_cmd)
            if code == 0 or code == true then
                return true, bin
            end
        end
        return false, "FFmpeg was not found in VLC environment. Run ./scripts/get-ffmpeg.sh or click 'Export Cut Script'."
    end
end

--- Build individual FFmpeg cut command
-- Uses lossless stream copy (-c copy) with input seeking for maximum speed
function CutterService.build_cut_command(video_path, scene, output_path, is_win, ffmpeg_bin, work_dir)
    if is_win == nil then is_win = Platform.is_windows end
    local bin = ffmpeg_bin or "ffmpeg"
    local start_str = scene.start_tc:to_string(true, ".")
    local end_str   = scene.end_tc:to_string(true, ".")
    output_path = output_path or CutterService.derive_output_path(video_path, scene, work_dir)

    local q_bin = Platform.quote(bin, is_win)
    local q_in  = Platform.quote(video_path, is_win)
    local q_out = Platform.quote(output_path, is_win)

    return string.format("%s -nostdin -y -ss %s -to %s -i %s -c copy %s", q_bin, start_str, end_str, q_in, q_out)
end

--- Generate complete batch cut script for all scenes
function CutterService.generate_script(video_path, scenes, is_win, work_dir)
    if is_win == nil then is_win = Platform.is_windows end
    local lines = {}

    if is_win then
        table.insert(lines, "@echo off")
        table.insert(lines, "chcp 65001 >nul")
        table.insert(lines, "REM Batch cut script generated by VLC ReelMaker")
        table.insert(lines, 'echo ==================================================')
        table.insert(lines, 'echo Starting batch scene cutting with FFmpeg...')
        table.insert(lines, 'echo ==================================================')
        table.insert(lines, "")

        for _, sc in ipairs(scenes) do
            local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
            local status_msg = string.format("Cutting Scene %d: %s...", sc.id, sc.title)
            table.insert(lines, "echo " .. Platform.escape_batch_echo(status_msg))
            table.insert(lines, CutterService.build_cut_command(video_path, sc, out_path, true, "ffmpeg"))
            table.insert(lines, "")
        end

        table.insert(lines, 'echo All scenes cut successfully!')
        table.insert(lines, "pause")
    else
        table.insert(lines, "#!/usr/bin/env bash")
        table.insert(lines, "# Batch cut script generated by VLC ReelMaker")
        table.insert(lines, "set -euo pipefail")
        table.insert(lines, 'echo "=================================================="')
        table.insert(lines, 'echo "Starting batch scene cutting with FFmpeg..."')
        table.insert(lines, 'echo "=================================================="')
        table.insert(lines, "")

        for _, sc in ipairs(scenes) do
            local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
            local status_msg = string.format("Cutting Scene %d: %s...", sc.id, sc.title)
            table.insert(lines, "echo " .. Platform.quote(status_msg, false))
            table.insert(lines, CutterService.build_cut_command(video_path, sc, out_path, false, "ffmpeg"))
            table.insert(lines, "")
        end

        table.insert(lines, 'echo "All scenes cut successfully!"')
    end

    return table.concat(lines, "\n") .. "\n"
end

--- Export batch script to disk
-- @param video_path string Path to video file
-- @param scenes table Array of Scene entities
-- @param is_win boolean|nil Optional OS override
-- @param work_dir string|nil Optional target working directory
-- @param scn_path string|nil Optional associated .scn file path
function CutterService.export_script(video_path, scenes, is_win, work_dir, scn_path)
    if is_win == nil then is_win = Platform.is_windows end
    if not video_path or video_path == "" then
        return false, "Video path is required to export cut script"
    end
    if not scenes or #scenes == 0 then
        return false, "No scenes available to export"
    end

    local ext = Platform.script_ext(is_win)
    local dir, filename = video_path:match("^(.-)([^\\/]+)$")
    if not dir then dir = ""; filename = video_path end
    local stem = filename:match("^(.*)%.[^%.\\/]+$") or filename

    -- Derive script prefix including .scn name if present
    local script_prefix = stem
    if scn_path and scn_path:match("%S") then
        local scn_file = scn_path:match("([^\\/]+)$") or scn_path
        local scn_stem = scn_file:match("^(.*)%.[^%.\\/]+$") or scn_file
        if scn_stem and scn_stem ~= "" then
            if scn_stem == stem then
                script_prefix = stem
            elseif scn_stem:sub(1, #stem) == stem then
                script_prefix = scn_stem
            else
                script_prefix = stem .. "_" .. scn_stem
            end
        end
    end

    local script_dir = dir
    if work_dir and work_dir:match("%S") then
        work_dir = work_dir:match("^%s*(.-)%s*$")
        local sep = (work_dir:find("\\") or Platform.is_windows) and "\\" or "/"
        if not work_dir:match("[\\/]$") then
            work_dir = work_dir .. sep
        end
        script_dir = work_dir
    end

    local script_path = script_dir .. script_prefix .. "_cut_scenes" .. ext
    local script_content = CutterService.generate_script(video_path, scenes, is_win, work_dir)

    local f, err = io.open(script_path, "w")
    if not f then
        return false, "Failed to write script: " .. tostring(err)
    end

    f:write(script_content)
    f:close()

    -- On POSIX, grant execute permissions if chmod is available
    if not is_win and os and os.execute then
        os.execute("chmod +x " .. Platform.quote(script_path, false) .. " 2>/dev/null")
    end

    return true, script_path
end

--- Execute synchronous FFmpeg batch cut for multiple scenes in a single process
-- @param video_path string Path to media file
-- @param scenes table Array of Scene entities
-- @param is_win boolean Optional override for testing
-- @param work_dir string Optional custom working directory
-- @return boolean, table|string ok, out_paths_or_error_detail
function CutterService.cut_batch(video_path, scenes, is_win, work_dir)
    if is_win == nil then is_win = Platform.is_windows end
    if not video_path or video_path == "" then
        return false, "Video path is required for cutting"
    end
    if not scenes or #scenes == 0 then
        return false, "No scenes specified"
    end

    local has_ffmpeg, bin_or_err = CutterService.check_ffmpeg(is_win)
    if not has_ffmpeg then
        return false, bin_or_err
    end

    local log_file = Platform.temp_log_path("vlc_cut_batch.log", is_win)
    local q_log = Platform.quote(log_file, is_win)

    -- Initialize / truncate temporary log file
    local f_init = io.open(log_file, "w")
    if f_init then f_init:close() end

    local cmd_lines = {}
    local out_paths = {}
    for _, sc in ipairs(scenes) do
        local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
        table.insert(out_paths, out_path)
        local cmd = CutterService.build_cut_command(video_path, sc, out_path, is_win, bin_or_err)
        if is_win then
            table.insert(cmd_lines, cmd .. " >> " .. q_log .. " 2>&1")
            table.insert(cmd_lines, "if errorlevel 1 exit /b %errorlevel%")
        else
            table.insert(cmd_lines, cmd .. " >> " .. q_log .. " 2>&1")
        end
    end

    local batch_cmd
    if is_win then
        batch_cmd = table.concat(cmd_lines, "\r\n")
    else
        batch_cmd = "(" .. table.concat(cmd_lines, " && ") .. ")"
    end

    local success
    local code
    if is_win then
        success = Platform.execute_hidden(batch_cmd, true)
        code = success and 0 or 1
    else
        if not (os and os.execute) then
            return false, "os.execute is unavailable in this Lua environment"
        end
        code = os.execute(batch_cmd)
        success = (code == 0 or code == true)
    end

    if success then
        return true, out_paths
    else
        local err_detail = "Exit code " .. tostring(code)
        local f_log = io.open(log_file, "r")
        local log_body = ""
        if f_log then
            local last_lines = {}
            for line in f_log:lines() do
                log_body = log_body .. line .. "\n"
                line = line:match("^%s*(.-)%s*$")
                if line ~= "" then
                    table.insert(last_lines, line)
                    if #last_lines > 4 then table.remove(last_lines, 1) end
                end
            end
            f_log:close()
            if #last_lines > 0 then
                err_detail = table.concat(last_lines, " | ")
            end
        end

        local target_dir = (work_dir and work_dir ~= "") and work_dir or video_path:match("^(.*[\\/])")
        if target_dir and log_body ~= "" then
            local sep = (target_dir:find("\\") or is_win) and "\\" or "/"
            if not target_dir:match("[\\/]$") then target_dir = target_dir .. sep end
            local mirror_log = target_dir .. "vlc_cut_batch.log"
            local f_m = io.open(mirror_log, "w")
            if f_m then
                f_m:write(log_body)
                f_m:close()
            end
        end

        local prefix = #scenes == 1 and "FFmpeg failed" or "FFmpeg batch cut failed"
        return false, string.format("%s (%s). Log: %s", prefix, err_detail, log_file)
    end
end

--- Execute synchronous FFmpeg cut for single scene with exit code inspection & error logging
-- Lossless stream copy (-c copy) finishes in 50-200ms without noticeable UI pause
-- Delegates to cut_batch for consistent execution semantics across all platforms
-- @param video_path string Path to media file
-- @param scene Scene Target scene entity
-- @param is_win boolean Optional override for testing
-- @param work_dir string Optional custom working directory
-- @return boolean, string ok, out_path_or_error_detail
function CutterService.cut_scene(video_path, scene, is_win, work_dir)
    if not scene then
        return false, "No scene specified"
    end
    local ok, res = CutterService.cut_batch(video_path, { scene }, is_win, work_dir)
    if ok and type(res) == "table" and res[1] then
        return true, res[1]
    end
    return ok, res
end

return CutterService
