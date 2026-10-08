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
        -- Check dedicated VLC tools directory in AppData
        local appdata = os.getenv("APPDATA")
        if appdata then
            local p = appdata .. "\\vlc\\bin\\ffmpeg.exe"
            local f = io.open(p, "r")
            if f then f:close(); return p end
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

        return "ffmpeg"
    end
end

--- Verify that FFmpeg is accessible and executable
-- @param is_win boolean Optional override for testing
-- @return boolean, string ok, binary_or_error
function CutterService.check_ffmpeg(is_win)
    if is_win == nil then is_win = Platform.is_windows end
    local bin = CutterService.find_ffmpeg(is_win)

    -- Test executing binary with -version
    local probe_cmd
    if is_win then
        probe_cmd = Platform.quote(bin, true) .. " -version > NUL 2>&1"
    else
        probe_cmd = Platform.quote(bin, false) .. " -version > /dev/null 2>&1"
    end

    if os and os.execute then
        local code = os.execute(probe_cmd)
        -- In Lua 5.1/LuaJIT, os.execute returns 0 or true on success
        if code == 0 or code == true then
            return true, bin
        end
    end

    if is_win then
        return false, "FFmpeg was not found in PATH or %APPDATA%\\vlc\\bin\\. Run scripts\\install-ffmpeg-windows.bat or click 'Export Cut Script'."
    else
        return false, "FFmpeg was not found in VLC environment. Run ./scripts/get-ffmpeg.sh or click 'Export Cut Script'."
    end
end

--- Build individual FFmpeg cut command
-- Uses lossless stream copy (-c copy) with input seeking for maximum speed
function CutterService.build_cut_command(video_path, scene, output_path, is_win, ffmpeg_bin, work_dir)
    local bin = ffmpeg_bin or "ffmpeg"
    local start_str = scene.start_tc:to_string(true, ".")
    local end_str   = scene.end_tc:to_string(true, ".")
    output_path = output_path or CutterService.derive_output_path(video_path, scene, work_dir)

    local q_bin = Platform.quote(bin, is_win)
    local q_in  = Platform.quote(video_path, is_win)
    local q_out = Platform.quote(output_path, is_win)

    return string.format("%s -y -ss %s -to %s -i %s -c copy %s", q_bin, start_str, end_str, q_in, q_out)
end

--- Generate complete batch cut script for all scenes
function CutterService.generate_script(video_path, scenes, is_win, work_dir)
    if is_win == nil then is_win = Platform.is_windows end
    local lines = {}

    if is_win then
        table.insert(lines, "@echo off")
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

--- Execute synchronous FFmpeg cut for single scene with exit code inspection & error logging
-- Lossless stream copy (-c copy) finishes in 50-200ms without noticeable UI pause
-- @param video_path string Path to media file
-- @param scene Scene Target scene entity
-- @param is_win boolean Optional override for testing
-- @param work_dir string Optional custom working directory
-- @return boolean, string ok, out_path_or_error_detail
function CutterService.cut_scene(video_path, scene, is_win, work_dir)
    if not video_path or video_path == "" then
        return false, "Video path is required for cutting"
    end
    if not scene then
        return false, "No scene specified"
    end

    -- Verify FFmpeg binary is available before launching
    local has_ffmpeg, bin_or_err = CutterService.check_ffmpeg(is_win)
    if not has_ffmpeg then
        return false, bin_or_err
    end

    local out_path = CutterService.derive_output_path(video_path, scene, work_dir)
    local log_file = Platform.temp_log_path(string.format("vlc_cut_scene_%d.log", scene.id), is_win)
    local q_log = Platform.quote(log_file, is_win)

    local raw_cmd = CutterService.build_cut_command(video_path, scene, out_path, is_win, bin_or_err)
    local full_cmd = raw_cmd .. " > " .. q_log .. " 2>&1"

    if not (os and os.execute) then
        return false, "os.execute is unavailable in this Lua environment"
    end

    local code = os.execute(full_cmd)
    local success = (code == 0 or code == true)

    if success then
        local f = io.open(out_path, "r")
        if f then
            f:close()
            return true, out_path
        else
            return false, "FFmpeg exited successfully, but output file was not created: " .. out_path
        end
    else
        -- Extract error from FFmpeg log file
        local err_detail = "Exit code " .. tostring(code)
        local f_log = io.open(log_file, "r")
        if f_log then
            local last_lines = {}
            for line in f_log:lines() do
                line = line:match("^%s*(.-)%s*$")
                if line ~= "" then
                    table.insert(last_lines, line)
                    if #last_lines > 4 then
                        table.remove(last_lines, 1)
                    end
                end
            end
            f_log:close()
            if #last_lines > 0 then
                err_detail = table.concat(last_lines, " | ")
            end
        end
        return false, string.format("FFmpeg failed (%s). Log: %s", err_detail, log_file)
    end
end

return CutterService
