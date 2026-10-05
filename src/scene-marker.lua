-- VLC Lua Extension : SceneMarker
-- Version           : 1.1
-- Author            : Konstantin Litvin & Antigravity
-- Description       : Fragment capture (Mark In / Mark Out), scene navigation, FFmpeg cutting, and .scn persistence

--------------------------------------------------
-- 1. Descriptor
--------------------------------------------------
function descriptor()
    return {
        title        = "Scene Marker",
        version      = "1.2",
        author       = "Konstantin Litvin & Antigravity",
        shortdesc    = "Fragment capture, scene navigation & cutting",
        description  = "Mark fragment start and end timestamps, export/cut via FFmpeg, save directly to .scn files, and navigate scenes.",
        capabilities = { "menu" }
    }
end

--------------------------------------------------
-- 2. Value Object: TimeCode
--------------------------------------------------
local TimeCode = {}
TimeCode.__index = TimeCode

--- Create TimeCode from total seconds (float)
-- @param sec number Total seconds
function TimeCode.from_seconds(sec)
    local self = setmetatable({}, TimeCode)
    self.total_sec = math.max(0, tonumber(sec) or 0)
    return self
end

--- Parse TimeCode from string ("HH:MM:SS", "HH:MM:SS,mmm", or "HH:MM:SS.mmm")
-- @param str string Timestamp string
function TimeCode.from_string(str)
    if type(str) ~= "string" then return nil, "Invalid string" end
    local trimmed = str:match("^%s*(.-)%s*$") or ""
    if #trimmed > 12 then
        return nil, string.format("Timecode exceeds maximum length of 12 characters (got %d chars)", #trimmed)
    end

    local h, m, s, sep, ms = trimmed:match("^(%d+):(%d+):(%d+)([,.]?)(%d*)$")
    if not (h and m and s) then
        return nil, "Invalid format (expected HH:MM:SS or HH:MM:SS,mmm)"
    end

    local n_m = tonumber(m)
    local n_s = tonumber(s)
    if n_m >= 60 then
        return nil, "Minutes must be between 0 and 59"
    end
    if n_s >= 60 then
        return nil, "Seconds must be between 0 and 59"
    end
    if ms and #ms > 3 then
        return nil, "Milliseconds cannot exceed 3 digits"
    end

    local sec = tonumber(h) * 3600 + n_m * 60 + n_s
    if ms and #ms > 0 then
        local divisor = 10 ^ (#ms)
        sec = sec + (tonumber(ms) / divisor)
    end

    return TimeCode.from_seconds(sec)
end

--- Format TimeCode as "HH:MM:SS,mmm" or "HH:MM:SS" (or with '.' for FFmpeg)
-- @param with_ms boolean Whether to include milliseconds (default: true)
-- @param delimiter string Millisecond delimiter ("," for SRT/SCN, "." for FFmpeg)
function TimeCode:to_string(with_ms, delimiter)
    if with_ms == nil then with_ms = true end
    delimiter = delimiter or ","
    local total = self.total_sec
    local s_int = math.floor(total)
    local h = math.floor(s_int / 3600)
    local m = math.floor((s_int % 3600) / 60)
    local s = s_int % 60
    local ms = math.floor(((total - s_int) * 1000) + 0.5)

    if ms >= 1000 then
        ms = 0
        s = s + 1
        if s >= 60 then
            s = 0
            m = m + 1
            if m >= 60 then
                m = 0
                h = h + 1
            end
        end
    end

    if with_ms then
        return string.format("%02d:%02d:%02d%s%03d", h, m, s, delimiter, ms)
    else
        return string.format("%02d:%02d:%02d", h, m, s)
    end
end

-- Metamethods for idiomatic comparison
function TimeCode.__lt(a, b)
    return a.total_sec < b.total_sec
end

function TimeCode.__le(a, b)
    return a.total_sec <= b.total_sec
end

function TimeCode.__eq(a, b)
    return math.abs(a.total_sec - b.total_sec) < 0.0005
end

function TimeCode:__tostring()
    return self:to_string(true, ",")
end

--------------------------------------------------
-- 3. Domain Entity: Scene
--------------------------------------------------
local Scene = {}
Scene.__index = Scene

--- Create a new Scene entity
-- @param id number Scene identifier
-- @param start_tc TimeCode Start timecode
-- @param end_tc TimeCode End timecode
-- @param title string Scene title
function Scene.new(id, start_tc, end_tc, title)
    if not (start_tc and end_tc) then
        return nil, "Start and End timecodes are required"
    end
    if end_tc <= start_tc then
        return nil, "End timestamp must be strictly greater than start timestamp"
    end

    local self = setmetatable({}, Scene)
    self.id = tonumber(id) or 1
    self.start_tc = start_tc
    self.end_tc = end_tc
    self.title = (title and title:match("^%s*(.-)%s*$")) or "Untitled Scene"
    if self.title == "" then self.title = "Untitled Scene" end
    return self
end

function Scene:duration()
    return self.end_tc.total_sec - self.start_tc.total_sec
end

Scene.TABLE_HEADER = "ID   Start                   End                     Title"

function Scene:to_table_row()
    return string.format(
        "%-3d   %s   %s   %s",
        self.id,
        self.start_tc:to_string(true, ","),
        self.end_tc:to_string(true, ","),
        self.title
    )
end

function Scene:to_scn_block()
    return string.format(
        "%d\n%s --> %s\n%s",
        self.id,
        self.start_tc:to_string(true, ","),
        self.end_tc:to_string(true, ","),
        self.title
    )
end

--------------------------------------------------
-- 4. Infrastructure: Platform Abstraction
--------------------------------------------------
local Platform = {}
Platform.is_windows = (package and package.config and package.config:sub(1, 1) == "\\") or false

--- Properly quote argument for the host OS shell
-- @param str string Raw argument or path
-- @param is_win boolean Optional override for testing
function Platform.quote(str, is_win)
    if is_win == nil then is_win = Platform.is_windows end
    str = tostring(str or "")
    if is_win then
        -- Windows cmd.exe: wrap in double quotes, escape double quotes by doubling them
        local escaped = str:gsub('"', '""')
        return '"' .. escaped .. '"'
    else
        -- POSIX shell: wrap in single quotes, escape single quotes
        local escaped = str:gsub("'", "'\\''")
        return "'" .. escaped .. "'"
    end
end

--- Format non-blocking background command execution
-- @param cmd string Core command line to run
-- @param log_path string Log file destination
-- @param is_win boolean Optional override for testing
function Platform.bg_command(cmd, log_path, is_win)
    if is_win == nil then is_win = Platform.is_windows end
    if is_win then
        -- Windows: start /B runs process in background without opening a new console window
        local log = log_path or "%TEMP%\\scene_marker_cut.log"
        return string.format('start "" /B cmd /c "%s > %s 2>&1"', cmd, log)
    else
        -- POSIX: trailing & detaches process to prevent freezing VLC UI thread
        local log = log_path or "/tmp/scene_marker_cut.log"
        return string.format("%s > %s 2>&1 &", cmd, Platform.quote(log, false))
    end
end

--- Get platform temporary log file path
-- @param filename string Base log filename
-- @param is_win boolean Optional override for testing
-- @return string Full path to temporary log file
function Platform.temp_log_path(filename, is_win)
    if is_win == nil then is_win = Platform.is_windows end
    if is_win then
        local t = os.getenv("TEMP") or os.getenv("TMP") or "C:\\temp"
        return t .. "\\" .. filename
    else
        local t = os.getenv("TMPDIR") or "/tmp"
        return t .. "/" .. filename
    end
end

--- Get script extension for current platform
-- @param is_win boolean Optional override for testing
function Platform.script_ext(is_win)
    if is_win == nil then is_win = Platform.is_windows end
    return is_win and ".bat" or ".sh"
end

--- Check whether a file path is absolute
-- @param path string Target file path
-- @param is_win boolean Optional override for testing
-- @return boolean True if path is absolute
function Platform.is_absolute(path, is_win)
    if not path or path == "" then return false end
    if is_win == nil then is_win = Platform.is_windows end
    if is_win then
        return (path:match("^%a:[\\/]") ~= nil) or (path:match("^[\\/][\\/]") ~= nil)
    else
        return path:sub(1, 1) == "/" or path:sub(1, 1) == "~"
    end
end

--- Resolve a .scn file path against a working directory and optional fallback directory
-- @param p string User-provided file path or name
-- @param work_dir string|nil Configured working directory
-- @param fallback_dir string|nil Fallback directory (e.g. video directory)
-- @param is_win boolean Optional override for testing
-- @return string Resolved absolute or fully-qualified path
function Platform.resolve_scn(p, work_dir, fallback_dir, is_win)
    if not p or p:match("^%s*$") then return "" end
    p = p:match("^%s*(.-)%s*$")

    -- Auto-append .scn extension if missing
    if not p:match("%.[^%.\\/]+$") then
        p = p .. ".scn"
    end

    if Platform.is_absolute(p, is_win) then
        return p
    end

    -- Determine base directory: work_dir > fallback_dir
    local base = nil
    if work_dir and work_dir:match("%S") then
        base = work_dir:match("^%s*(.-)%s*$")
    elseif fallback_dir and fallback_dir:match("%S") then
        base = fallback_dir:match("^%s*(.-)%s*$")
    end

    if not base or base == "" then
        return p
    end

    if is_win == nil then is_win = Platform.is_windows end
    local sep = (base:find("\\") or is_win) and "\\" or "/"
    if not base:match("[\\/]$") then
        base = base .. sep
    end

    return base .. p
end

--- Return relative filename if path is inside work_dir, otherwise return original path
-- @param path string Full or relative path to file
-- @param work_dir string|nil Working directory
-- @return string Relative filename if inside work_dir, or original path
function Platform.relative_display(path, work_dir)
    if not path or path == "" then return "" end
    if not work_dir or work_dir == "" then return path end

    local norm_wd = work_dir:gsub("\\", "/"):gsub("/+$", "") .. "/"
    local norm_p = path:gsub("\\", "/")
    if norm_p:sub(1, #norm_wd) == norm_wd then
        return norm_p:sub(#norm_wd + 1)
    end
    return path
end

--------------------------------------------------
-- 5. Domain Service: CutterService (FFmpeg)
--------------------------------------------------
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
        table.insert(lines, "REM Batch cut script generated by VLC Scene Marker")
        table.insert(lines, 'echo ==================================================')
        table.insert(lines, 'echo Starting batch scene cutting with FFmpeg...')
        table.insert(lines, 'echo ==================================================')
        table.insert(lines, "")

        for _, sc in ipairs(scenes) do
            local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
            table.insert(lines, string.format('echo Cutting Scene %d: %s...', sc.id, sc.title))
            table.insert(lines, CutterService.build_cut_command(video_path, sc, out_path, true, "ffmpeg"))
            table.insert(lines, "")
        end

        table.insert(lines, 'echo All scenes cut successfully!')
        table.insert(lines, "pause")
    else
        table.insert(lines, "#!/usr/bin/env bash")
        table.insert(lines, "# Batch cut script generated by VLC Scene Marker")
        table.insert(lines, "set -euo pipefail")
        table.insert(lines, 'echo "=================================================="')
        table.insert(lines, 'echo "Starting batch scene cutting with FFmpeg..."')
        table.insert(lines, 'echo "=================================================="')
        table.insert(lines, "")

        for _, sc in ipairs(scenes) do
            local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
            table.insert(lines, string.format('echo "Cutting Scene %d: %s..."', sc.id, sc.title))
            table.insert(lines, CutterService.build_cut_command(video_path, sc, out_path, false, "ffmpeg"))
            table.insert(lines, "")
        end

        table.insert(lines, 'echo "All scenes cut successfully!"')
    end

    return table.concat(lines, "\n") .. "\n"
end

--- Export batch script to disk
function CutterService.export_script(video_path, scenes, is_win, work_dir)
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

    local script_dir = dir
    if work_dir and work_dir:match("%S") then
        work_dir = work_dir:match("^%s*(.-)%s*$")
        local sep = (work_dir:find("\\") or Platform.is_windows) and "\\" or "/"
        if not work_dir:match("[\\/]$") then
            work_dir = work_dir .. sep
        end
        script_dir = work_dir
    end

    local script_path = script_dir .. stem .. "_cut_scenes" .. ext
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

-- Backward compatibility alias
CutterService.cut_scene_async = CutterService.cut_scene

--------------------------------------------------
-- 6. Repository: SceneRepository
--------------------------------------------------
local SceneRepository = {}
SceneRepository.__index = SceneRepository

function SceneRepository.new()
    local self = setmetatable({}, SceneRepository)
    self.scenes = {}
    self.file_path = ""
    return self
end

--- Clear all scenes from repository and reset active file path
function SceneRepository:clear()
    self.scenes = {}
    self.file_path = ""
end

--- Parse an SCN file from disk
-- @param path string File system path
function SceneRepository:load(path)
    if not path or path == "" then
        return false, "File path is required"
    end

    local f, err = io.open(path, "r")
    if not f then
        return false, "Could not open file: " .. tostring(err)
    end

    local loaded_scenes = {}
    local block = {}

    local function parse_block(b)
        if #b < 3 then return end
        local id = tonumber(b[1])
        local times = b[2]
        local title = b[3]

        local s_str, e_str = times:match("^(.-)%s*%-%->%s*(.-)$")
        if not (s_str and e_str and title) then return end

        local start_tc = TimeCode.from_string(s_str)
        local end_tc = TimeCode.from_string(e_str)
        if not (start_tc and end_tc) then return end

        local sc = Scene.new(id or (#loaded_scenes + 1), start_tc, end_tc, title)
        if sc then
            table.insert(loaded_scenes, sc)
        end
    end

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" then
            parse_block(block)
            block = {}
        else
            table.insert(block, line)
        end
    end
    parse_block(block)
    f:close()

    self.scenes = loaded_scenes
    self.file_path = path
    self:sort_and_reindex()

    return true, #self.scenes
end

--- Sort scenes chronologically and renumber IDs (1..N)
function SceneRepository:sort_and_reindex()
    table.sort(self.scenes, function(a, b)
        return a.start_tc < b.start_tc
    end)
    for i, sc in ipairs(self.scenes) do
        sc.id = i
    end
end

--- Add a new scene and sort/reindex
-- @param start_tc TimeCode
-- @param end_tc TimeCode
-- @param title string
function SceneRepository:add(start_tc, end_tc, title)
    local sc, err = Scene.new(#self.scenes + 1, start_tc, end_tc, title)
    if not sc then
        return false, err
    end

    table.insert(self.scenes, sc)
    self:sort_and_reindex()
    return true, sc
end

--- Save all scenes to the specified file path
-- @param path string File path (optional, defaults to current file_path)
function SceneRepository:save(path)
    local target_path = path or self.file_path
    if not target_path or target_path == "" then
        return false, "File path is required for saving"
    end

    local f, err = io.open(target_path, "w")
    if not f then
        return false, "Failed to write file: " .. tostring(err)
    end

    for i, sc in ipairs(self.scenes) do
        f:write(sc:to_scn_block())
        if i < #self.scenes then
            f:write("\n\n")
        else
            f:write("\n")
        end
    end
    f:close()
    self.file_path = target_path
    return true
end

function SceneRepository:get_by_id(id)
    for _, sc in ipairs(self.scenes) do
        if sc.id == id then return sc end
    end
    return nil
end

--- Delete scene by ID and reindex remaining scenes
-- @param id number Scene ID to delete
-- @return boolean, Scene|string ok, deleted_scene_or_error
function SceneRepository:delete(id)
    local found_idx = nil
    for i, sc in ipairs(self.scenes) do
        if sc.id == id then
            found_idx = i
            break
        end
    end

    if not found_idx then
        return false, "Scene not found for ID: " .. tostring(id)
    end

    local deleted = table.remove(self.scenes, found_idx)
    self:sort_and_reindex()
    return true, deleted
end

--- Delete multiple scenes by IDs and reindex remaining scenes
-- @param ids table Array of scene IDs to delete
-- @return boolean, number|string ok, deleted_count_or_error
function SceneRepository:delete_many(ids)
    if not ids or #ids == 0 then
        return false, "No scene IDs provided to delete"
    end

    local id_set = {}
    for _, id in ipairs(ids) do
        local n = tonumber(id)
        if n then id_set[n] = true end
    end

    local kept = {}
    local deleted_count = 0
    for _, sc in ipairs(self.scenes) do
        if id_set[sc.id] then
            deleted_count = deleted_count + 1
        else
            table.insert(kept, sc)
        end
    end

    if deleted_count == 0 then
        return false, "No matching scenes found to delete"
    end

    self.scenes = kept
    self:sort_and_reindex()
    return true, deleted_count
end

--- Update existing scene by ID, re-sort and re-index
-- @param id number Scene ID to update
-- @param start_tc TimeCode
-- @param end_tc TimeCode
-- @param title string
-- @return boolean, Scene|string ok, updated_scene_or_error
function SceneRepository:update(id, start_tc, end_tc, title)
    local sc = self:get_by_id(id)
    if not sc then
        return false, "Scene not found for ID: " .. tostring(id)
    end

    if end_tc <= start_tc then
        return false, "End time must be greater than Start time"
    end

    sc.start_tc = start_tc
    sc.end_tc = end_tc
    if title and title:match("%S") then
        sc.title = title:match("^%s*(.-)%s*$")
    end
    self:sort_and_reindex()
    return true, sc
end

function SceneRepository:count()
    return #self.scenes
end

--------------------------------------------------
-- 7. Infrastructure Port: VlcPlayerAdapter
--------------------------------------------------
local VlcPlayerAdapter = {}

--- Query active playback timecode
-- @return TimeCode, error_message
function VlcPlayerAdapter.get_current_time()
    if not vlc or not vlc.object then
        return nil, "VLC runtime not available"
    end

    local input = vlc.object.input()
    if not input then
        return nil, "No media currently playing"
    end

    -- In VLC Lua API, "time" returns microseconds (int64)
    local us = vlc.var.get(input, "time")
    if not us or us < 0 then
        return nil, "Unable to read current playback position"
    end

    return TimeCode.from_seconds(us / 1000000)
end

--- Seek playback to given timecode non-blockingly
-- @param tc TimeCode
function VlcPlayerAdapter.seek(tc)
    if not vlc or not vlc.object then
        return false, "VLC runtime not available"
    end

    local input = vlc.object.input()
    if not input then
        return false, "No media currently playing"
    end

    local sec = tc.total_sec
    if vlc.input and vlc.input.seek then
        vlc.input.seek(sec)
    else
        vlc.var.set(input, "time", math.floor(sec * 1000000))
    end
    return true
end

--- Get video file system path from playing item
function VlcPlayerAdapter.get_video_path()
    if not vlc or not vlc.input or not vlc.input.item then return "" end
    local item = vlc.input.item()
    if not item then return "" end

    local uri = item:uri() or ""
    local path = (vlc.strings and vlc.strings.decode_uri) and vlc.strings.decode_uri(uri) or uri
    path = path:gsub("^file://", "")

    -- Windows path normalization (e.g. /C:/...)
    if path:match("^/[A-Z]:/") then
        path = path:sub(2)
    end
    return path
end

--- Guess work directory from playing item
function VlcPlayerAdapter.guess_work_dir()
    local path = VlcPlayerAdapter.get_video_path()
    if path ~= "" then
        local dir = path:match("^(.*[\\/])")
        return dir or ""
    end
    return ""
end

--- Guess .scn file path from playing item
function VlcPlayerAdapter.guess_scn_path()
    local path = VlcPlayerAdapter.get_video_path()
    if path ~= "" then
        return path:gsub("%.[^%.\\/]+$", ".scn")
    end
    return ""
end

--------------------------------------------------
-- 8. Application Controller & UI View
--------------------------------------------------
--- Wrap status text with <br> breaks, breaking at whitespace and directory slashes
local function wrap_status_text(text, max_len, max_lines)
    max_len = max_len or 55
    local out_lines = {}
    local normalized = tostring(text):gsub("<br%s*/?>", "\n")
    for raw_line in (normalized .. "\n"):gmatch("(.-)\r?\n") do
        if #raw_line <= max_len then
            table.insert(out_lines, raw_line)
        else
            local cur = ""
            for token in raw_line:gmatch("%S+") do
                local pieces = {}
                if #token > max_len then
                    local p_cur = ""
                    for seg in token:gmatch("[\\/]?[^\\/]+") do
                        if #p_cur + #seg > max_len and #p_cur > 0 then
                            table.insert(pieces, p_cur)
                            p_cur = seg
                        else
                            p_cur = p_cur .. seg
                        end
                        while #p_cur > max_len do
                            table.insert(pieces, p_cur:sub(1, max_len))
                            p_cur = p_cur:sub(max_len + 1)
                        end
                    end
                    if token:match("[\\/]$") and #p_cur > 0 and not p_cur:match("[\\/]$") then
                        p_cur = p_cur .. token:match("[\\/]$")
                    end
                    if #p_cur > 0 then
                        table.insert(pieces, p_cur)
                    end
                else
                    table.insert(pieces, token)
                end

                for _, piece in ipairs(pieces) do
                    if #cur == 0 then
                        cur = piece
                    elseif #cur + 1 + #piece <= max_len then
                        cur = cur .. " " .. piece
                    else
                        table.insert(out_lines, cur)
                        cur = piece
                    end
                end
            end
            if #cur > 0 then
                table.insert(out_lines, cur)
            end
        end
    end

    if max_lines and #out_lines > max_lines then
        local trimmed = {}
        for i = 1, max_lines - 1 do
            table.insert(trimmed, out_lines[i])
        end
        local last_line = out_lines[max_lines]
        if #last_line > max_len - 3 then
            last_line = last_line:sub(1, max_len - 3)
        end
        table.insert(trimmed, last_line .. "...")
        out_lines = trimmed
    end

    return table.concat(out_lines, "<br>")
end

local function html_escape(str)
    return (tostring(str or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local app = {
    repo               = nil,
    dlg                = nil,
    workdir_input      = nil,
    path_input         = nil,
    list               = nil,
    start_input        = nil,
    end_input          = nil,
    title_input        = nil,
    status_box         = nil,
    status_label       = nil, -- retained for backward-compatibility in test mocks
    editing_scene      = nil,
    editing_scene_id   = nil,
    pending_delete_ids = nil,
    pending_new_confirm = nil,
    loaded_video_path  = "",
    loaded_scn_path    = ""
}

function app:set_status(msg, level)
    local color = "#333333"
    if level == "error" or msg:find("❌") then
        color = "#c62828"
    elseif level == "success" or msg:find("✅") then
        color = "#2e7d32"
    elseif level == "warn" or msg:find("⚠️") then
        color = "#e65100"
    end

    local raw_lines = {}
    local normalized = tostring(msg):gsub("<br%s*/?>", "\n")
    for line in (normalized .. "\n"):gmatch("(.-)\r?\n") do
        table.insert(raw_lines, line)
    end
    if #raw_lines > 1 and raw_lines[#raw_lines] == "" then
        table.remove(raw_lines)
    end

    local display_lines = {}
    local max_visible_lines = 4
    if #raw_lines <= max_visible_lines then
        for _, l in ipairs(raw_lines) do
            table.insert(display_lines, html_escape(l))
        end
    else
        for i = 1, max_visible_lines - 1 do
            table.insert(display_lines, html_escape(raw_lines[i]))
        end
        table.insert(display_lines, "... (see log file for full details)")
    end

    local formatted = table.concat(display_lines, "<br>")
    local html = string.format("<div style='font-family:sans-serif; font-size:11px; margin:0; padding:0; line-height:1.3; word-wrap:break-word; color:%s;'>%s</div>", color, formatted)

    if self.status_box then
        self.status_box:set_text(html)
    end
    if self.status_label then
        self.status_label:set_text(html)
    end
    if vlc and vlc.msg then
        vlc.msg.dbg("[SceneMarker] " .. msg:gsub("<[^>]+>", ""))
    end
end

function app:get_work_dir()
    if self.workdir_input then
        local wd = self.workdir_input:get_text()
        if wd and wd:match("%S") then
            return wd:match("^%s*(.-)%s*$")
        end
    end
    return nil
end

function app:get_scn_path()
    if not self.path_input then return "" end
    local p = self.path_input:get_text()
    local wd = self:get_work_dir()
    local fallback = VlcPlayerAdapter.guess_work_dir()
    return Platform.resolve_scn(p, wd, fallback)
end

function app:cancel_edit()
    self.editing_scene = nil
    self.editing_scene_id = nil
    if self.start_input then self.start_input:set_text("") end
    if self.end_input then self.end_input:set_text("") end
    if self.title_input then self.title_input:set_text("") end
end

function app:refresh_list()
    if not self.list then return end
    self.list:clear()
    self.list:add_value(Scene.TABLE_HEADER, 0)

    for _, sc in ipairs(self.repo.scenes) do
        self.list:add_value(sc:to_table_row(), sc.id)
    end
end

function app:on_new_file()
    self.pending_delete_ids = nil

    if self.repo and self.repo:count() > 0 and not self.pending_new_confirm then
        self.pending_new_confirm = true
        self:set_status("⚠️ In-memory scene list is not empty. Click 'New' again to clear and start fresh.", "warn")
        return
    end
    self.pending_new_confirm = nil

    self:cancel_edit()
    if self.repo then
        self.repo:clear()
    end
    self.loaded_scn_path = ""
    self.loaded_video_path = VlcPlayerAdapter.get_video_path()

    self:refresh_list()

    local cur_path = self.path_input and self.path_input:get_text() or ""
    if cur_path == "" or (self.loaded_scn_path and cur_path == self.loaded_scn_path) then
        local guessed = VlcPlayerAdapter.guess_scn_path()
        if guessed ~= "" then
            local stem = guessed:match("^(.*)%.scn$") or guessed
            local new_target = stem .. "_new.scn"
            local wd = self:get_work_dir() or VlcPlayerAdapter.guess_work_dir()
            local display_new = Platform.relative_display(new_target, wd)
            if self.path_input then self.path_input:set_text(display_new) end
        end
    end

    self:set_status("✨ Started new empty scene list. Set .scn File, mark timestamps, and click Add / Save Scene.")
end

function app:on_load_file()
    self:cancel_edit()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local path = self:get_scn_path()
    if not path or path == "" then
        self:set_status("⚠️ Please enter a valid .scn file path.")
        return
    end

    local f = io.open(path, "r")
    if not f then
        local basename = path:match("([^\\/]+)$") or path
        self:set_status(string.format("❌ File not found: '%s'. Click 'New' to create a new scene file.", basename), "error")
        return
    end
    f:close()

    local ok, res = self.repo:load(path)
    if not ok then
        self.list:clear()
        self.list:add_value(Scene.TABLE_HEADER, 0)
        self.list:add_value("Could not open file.", 1)
        self:set_status("❌ " .. tostring(res), "error")
        return
    end

    self.loaded_scn_path = path
    self.loaded_video_path = VlcPlayerAdapter.get_video_path()

    self:refresh_list()
    local basename = path:match("([^\\/]+)$") or path
    self:set_status(string.format("✅ Loaded %d scene(s) from %s", res, basename))
end

function app:on_save_as()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local path = self:get_scn_path()
    if not path or path == "" then
        self:set_status("⚠️ Target .scn file path is required to save scenes.")
        return
    end

    if not self.repo or self.repo:count() == 0 then
        self:set_status("⚠️ No scenes to save. Add scenes first.", "warn")
        return
    end

    local ok, res = self.repo:save(path)
    if not ok then
        self:set_status("❌ Failed to save file: " .. tostring(res), "error")
        return
    end

    self.loaded_scn_path = path
    self.loaded_video_path = VlcPlayerAdapter.get_video_path()
    local basename = path:match("([^\\/]+)$") or path
    self:set_status(string.format("💾 Saved %d scene(s) to %s", self.repo:count(), basename))
end

function app:on_mark_start()
    self.pending_new_confirm = nil
    local tc, err = VlcPlayerAdapter.get_current_time()
    if not tc then
        self:set_status("⚠️ Cannot mark Start: " .. err)
        return
    end

    if self.start_input then
        self.start_input:set_text(tc:to_string(true, ","))
        self:set_status("⏱️ Start marked: " .. tc:to_string(true, ","))
    end
end

function app:on_mark_end()
    self.pending_new_confirm = nil
    local tc, err = VlcPlayerAdapter.get_current_time()
    if not tc then
        self:set_status("⚠️ Cannot mark End: " .. err)
        return
    end

    if self.end_input then
        self.end_input:set_text(tc:to_string(true, ","))
        self:set_status("⏱️ End marked: " .. tc:to_string(true, ","))
    end
end

function app:on_save_scene()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local path = self:get_scn_path()
    if not path or path == "" then
        self:set_status("⚠️ Target .scn file path is required to save scene.")
        return
    end

    local s_text = self.start_input and self.start_input:get_text() or ""
    local e_text = self.end_input and self.end_input:get_text() or ""
    local title  = self.title_input and self.title_input:get_text() or ""

    local start_tc, s_err = TimeCode.from_string(s_text)
    if not start_tc then
        self:set_status("⚠️ Invalid Start time: " .. tostring(s_err))
        return
    end

    local end_tc, e_err = TimeCode.from_string(e_text)
    if not end_tc then
        self:set_status("⚠️ Invalid End time: " .. tostring(e_err))
        return
    end

    if self.editing_scene or self.editing_scene_id then
        local target_sc = self.editing_scene
        if not target_sc and self.editing_scene_id then
            target_sc = self.repo:get_by_id(self.editing_scene_id)
        end

        local current_sc = target_sc and self.repo:get_by_id(target_sc.id)
        if not current_sc or current_sc ~= target_sc then
            self:cancel_edit()
            self:set_status("⚠️ The scene being edited was deleted or reloaded. Edit cancelled.", "warn")
            return
        end

        local ok, res = self.repo:update(target_sc.id, start_tc, end_tc, title)
        if not ok then
            self:set_status("❌ " .. tostring(res))
            return
        end

        local save_ok, save_err = self.repo:save(path)
        if not save_ok then
            self:set_status("⚠️ Updated in memory, but failed to save file: " .. tostring(save_err))
        else
            self:set_status(string.format("✅ Updated & saved Scene %d: '%s'", res.id, res.title))
        end

        self:cancel_edit()
    else
        if title:match("^%s*$") then
            title = string.format("Scene %d", self.repo:count() + 1)
        end

        local ok, res = self.repo:add(start_tc, end_tc, title)
        if not ok then
            self:set_status("❌ " .. tostring(res))
            return
        end

        local save_ok, save_err = self.repo:save(path)
        if not save_ok then
            self:set_status("⚠️ Added in memory, but failed to save file: " .. tostring(save_err))
        else
            self:set_status(string.format("✅ Added & saved Scene %d: '%s'", res.id, res.title))
        end

        if self.loaded_video_path == "" then
            self.loaded_video_path = VlcPlayerAdapter.get_video_path()
        end
        if self.loaded_scn_path == "" then
            self.loaded_scn_path = path
        end
    end

    self:refresh_list()
    self:cancel_edit()
end

-- Backward compatibility alias
app.on_add_scene = app.on_save_scene

function app:on_edit_selected()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local sc, err = self:get_selected_scene("Edit")
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    -- Toggle edit mode off if already editing this exact scene
    if self.editing_scene == sc or self.editing_scene_id == sc.id then
        self:cancel_edit()
        self:set_status(string.format("Cancelled editing Scene %d.", sc.id))
        return
    end

    self.editing_scene = sc
    self.editing_scene_id = sc.id
    if self.start_input then self.start_input:set_text(sc.start_tc:to_string(true, ",")) end
    if self.end_input then self.end_input:set_text(sc.end_tc:to_string(true, ",")) end
    if self.title_input then self.title_input:set_text(sc.title) end
    self:set_status(string.format("✏️ Editing Scene %d: modify Start, End, or Title, then click Add / Save Scene (or click ✏️ Edit to cancel).", sc.id))
end

function app:get_selected_scenes()
    if not self.list then return {} end
    local sel = self.list:get_selection()
    if not sel or next(sel) == nil then
        return {}
    end

    local scenes = {}
    for id_key, _ in pairs(sel) do
        local id_num = tonumber(id_key)
        if id_num and id_num > 0 then
            local sc = self.repo:get_by_id(id_num)
            if sc then
                table.insert(scenes, sc)
            end
        end
    end

    table.sort(scenes, function(a, b) return a.start_tc < b.start_tc end)
    return scenes
end

function app:get_selected_scene(action_name)
    if not self.list then return nil end
    local sel = self.list:get_selection()
    if not sel or next(sel) == nil then
        return nil, "No scene selected from the list"
    end

    local scenes = self:get_selected_scenes()
    if #scenes == 0 then
        return nil, "Header row selected; please select a scene row"
    elseif #scenes > 1 then
        action_name = action_name or "This action"
        return nil, string.format("Multiple scenes selected (%d selected); '%s' only applies to a single scene.", #scenes, action_name)
    end
    return scenes[1]
end

function app:on_jump_to_start()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local sc, err = self:get_selected_scene("To Start")
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local ok, seek_err = VlcPlayerAdapter.seek(sc.start_tc)
    if not ok then
        self:set_status("❌ " .. seek_err)
    else
        self:set_status(string.format("▶ Jumped Scene %d Start: %s", sc.id, sc.start_tc:to_string(true, ",")))
    end
end

function app:on_jump_to_end()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local sc, err = self:get_selected_scene("To End")
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local ok, seek_err = VlcPlayerAdapter.seek(sc.end_tc)
    if not ok then
        self:set_status("❌ " .. seek_err)
    else
        self:set_status(string.format("⏹ Jumped Scene %d End: %s", sc.id, sc.end_tc:to_string(true, ",")))
    end
end

function app:on_cut_selected()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local scenes = self:get_selected_scenes()
    if #scenes == 0 then
        self:set_status("⚠️ Please select one or more scenes from the list", "warn")
        return
    end

    local video_path = VlcPlayerAdapter.get_video_path()
    if not video_path or video_path == "" then
        self:set_status("⚠️ Cannot determine playing video file path", "warn")
        return
    end

    -- Video mismatch guard
    if self.loaded_video_path ~= "" and video_path ~= self.loaded_video_path then
        local old_name = self.loaded_video_path:match("([^\\/]+)$") or self.loaded_video_path
        local cur_name = video_path:match("([^\\/]+)$") or video_path
        self:set_status(string.format("❌ Video mismatch: Loaded scenes belong to '%s', but VLC is playing '%s'. Please reload the .scn file.", old_name, cur_name), "error")
        return
    end

    local work_dir = self:get_work_dir()
    local cut_count = 0
    local failed = {}

    for i, sc in ipairs(scenes) do
        if #scenes > 1 then
            self:set_status(string.format("⏳ Cutting scene %d of %d: '%s'...", i, #scenes, sc.title))
            if self.dlg and self.dlg.update then self.dlg:update() end
        end

        local ok, res = CutterService.cut_scene(video_path, sc, nil, work_dir)
        if ok then
            cut_count = cut_count + 1
        else
            table.insert(failed, string.format("Scene %d: %s", sc.id, tostring(res)))
        end
    end

    if #failed > 0 then
        local err_summary = table.concat(failed, "\n")
        self:set_status(string.format("⚠️ Cut %d of %d scene(s). Errors:\n%s", cut_count, #scenes, err_summary), "error")
    else
        if #scenes == 1 then
            local sc = scenes[1]
            local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
            local basename = out_path:match("([^\\/]+)$") or out_path
            self:set_status(string.format("✅ Scene %d cut complete: %s\nSaved to: %s", sc.id, basename, out_path), "success")
        else
            local target_dir = work_dir ~= "" and work_dir or (video_path:match("^(.*[\\/])") or "working directory")
            self:set_status(string.format("✅ Batch cut complete: all %d scenes cut successfully!\nSaved to: %s", cut_count, target_dir), "success")
        end
    end
end

function app:on_delete_selected()
    self.pending_new_confirm = nil
    local scenes = self:get_selected_scenes()
    if #scenes == 0 then
        self:set_status("⚠️ Please select one or more scenes to delete", "warn")
        self.pending_delete_ids = nil
        return
    end

    local ids = {}
    for _, sc in ipairs(scenes) do
        table.insert(ids, sc.id)
    end

    -- If deleting multiple scenes, require 2-step confirmation
    if #scenes > 1 then
        local is_confirmed = false
        if self.pending_delete_ids and #self.pending_delete_ids == #ids then
            is_confirmed = true
            for i, id in ipairs(ids) do
                if self.pending_delete_ids[i] ~= id then
                    is_confirmed = false
                    break
                end
            end
        end

        if not is_confirmed then
            self.pending_delete_ids = ids
            self:set_status(string.format("⚠️ Delete %d scenes? Click 🗑️ Delete again to confirm (or click any other button to cancel).", #ids), "warn")
            return
        end
    end

    self.pending_delete_ids = nil
    self:cancel_edit()

    local ok, res = self.repo:delete_many(ids)
    if not ok then
        self:set_status("❌ " .. tostring(res), "error")
        return
    end

    local path = self:get_scn_path()
    if path and path ~= "" then
        local save_ok, save_err = self.repo:save(path)
        if not save_ok then
            self:set_status(string.format("⚠️ Deleted %d scene(s) in memory, but failed to save file: %s", res, tostring(save_err)))
        else
            if #scenes == 1 then
                self:set_status(string.format("🗑️ Deleted Scene %d: '%s'", scenes[1].id, scenes[1].title))
            else
                self:set_status(string.format("🗑️ Deleted %d scenes and reindexed remaining scenes in .scn", res))
            end
        end
    else
        if #scenes == 1 then
            self:set_status(string.format("🗑️ Deleted Scene %d: '%s'.", scenes[1].id, scenes[1].title))
        else
            self:set_status(string.format("🗑️ Deleted %d scene(s).", res))
        end
    end

    self:refresh_list()
end

function app:on_export_script()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local video_path = VlcPlayerAdapter.get_video_path()
    if not video_path or video_path == "" then
        self:set_status("⚠️ Cannot determine playing video file path", "warn")
        return
    end

    if not self.repo or self.repo:count() == 0 then
        self:set_status("⚠️ No scenes to export into script", "warn")
        return
    end

    -- Video mismatch guard
    if self.loaded_video_path ~= "" and video_path ~= self.loaded_video_path then
        local old_name = self.loaded_video_path:match("([^\\/]+)$") or self.loaded_video_path
        local cur_name = video_path:match("([^\\/]+)$") or video_path
        self:set_status(string.format("❌ Video mismatch: Loaded scenes belong to '%s', but VLC is playing '%s'. Please reload the .scn file.", old_name, cur_name), "error")
        return
    end

    local targets = {}
    local selected = self:get_selected_scenes()
    if #selected > 0 then
        targets = selected
    else
        targets = self.repo.scenes
    end

    local work_dir = self:get_work_dir()
    local ok, res = CutterService.export_script(video_path, targets, nil, work_dir)
    if not ok then
        self:set_status("❌ Export script failed: " .. tostring(res), "error")
    else
        local basename = res:match("([^\\/]+)$") or res
        if #targets < self.repo:count() then
            self:set_status(string.format("🎬 Exported cut script for %d selected scene(s): %s", #targets, basename), "success")
        else
            self:set_status(string.format("🎬 Cut script exported (%d scenes): %s", #targets, basename), "success")
        end
    end
end

--------------------------------------------------
-- 9. VLC Extension Lifecycle Hooks & Menu
--------------------------------------------------
function activate()
    if app.dlg then return end

    if not app.repo then
        app.repo = SceneRepository.new()
    end
    app.dlg = vlc.dialog("Scene Marker")

    -- Row 1: File Actions (New, Load, Save As - 3 equal buttons, span 4 each)
    app.dlg:add_button("📄 New",     function() app:on_new_file() end,  1, 1, 4, 1)
    app.dlg:add_button("📂 Load",    function() app:on_load_file() end, 5, 1, 4, 1)
    app.dlg:add_button("💾 Save As", function() app:on_save_as() end,   9, 1, 4, 1)

    -- Row 2: Working Directory input (defaults to playing video directory)
    app.dlg:add_label("<b>Work Dir:</b>", 1, 2, 2, 1)
    local initial_work_dir = VlcPlayerAdapter.guess_work_dir()
    app.workdir_input = app.dlg:add_text_input(initial_work_dir, 3, 2, 10, 1)

    -- Row 3: .scn file input (relative filename if inside work directory)
    app.dlg:add_label("<b>.scn File:</b>", 1, 3, 2, 1)
    local initial_path = VlcPlayerAdapter.guess_scn_path()
    local initial_display = Platform.relative_display(initial_path, initial_work_dir)
    app.path_input = app.dlg:add_text_input(initial_display, 3, 3, 10, 1)

    -- Rows 4-11: Scenes list view (height 8, full width)
    app.list = app.dlg:add_list(1, 4, 12, 8)
    app.list:add_value(Scene.TABLE_HEADER, 0)

    -- Row 12: Scene Operations (Navigation, Edit, Delete - 4 equal buttons, span 3 each)
    app.dlg:add_button("⏮️ To Start", function() app:on_jump_to_start() end,    1, 12, 3, 1)
    app.dlg:add_button("⏭️ To End",   function() app:on_jump_to_end() end,      4, 12, 3, 1)
    app.dlg:add_button("✏️ Edit",     function() app:on_edit_selected() end,    7, 12, 3, 1)
    app.dlg:add_button("🗑️ Delete",   function() app:on_delete_selected() end, 10, 12, 3, 1)

    -- Row 13: Production / Output (FFmpeg Actions: Cut & Export Script - 2 equal buttons, span 6 each)
    app.dlg:add_button("✂️ Cut",             function() app:on_cut_selected() end, 1, 13, 6, 1)
    app.dlg:add_button("🎬 Export Cut Script", function() app:on_export_script() end, 7, 13, 6, 1)

    -- Row 14: Fragment Start input & Mark button
    app.dlg:add_label("<b>Start:</b>", 1, 14, 2, 1)
    app.start_input = app.dlg:add_text_input("", 3, 14, 3, 1)
    app.dlg:add_button("⏱️ Mark", function() app:on_mark_start() end, 6, 14, 2, 1)

    -- Row 15: Fragment End input & Mark button
    app.dlg:add_label("<b>End:</b>", 1, 15, 2, 1)
    app.end_input = app.dlg:add_text_input("", 3, 15, 3, 1)
    app.dlg:add_button("⏱️ Mark", function() app:on_mark_end() end, 6, 15, 2, 1)

    -- Row 16: Scene Title input & Add/Save Scene button
    app.dlg:add_label("<b>Title:</b>", 1, 16, 2, 1)
    app.title_input = app.dlg:add_text_input("", 3, 16, 6, 1)
    app.dlg:add_button("➕ Add / Save Scene", function() app:on_save_scene() end, 9, 16, 4, 1)

    -- Row 17: Fixed-height Scrollable & Copyable Status Area (QTextBrowser, height ~75-80px / ~4 lines, scrollbar as needed)
    app.status_box = app.dlg:add_html("<div style='font-family:sans-serif; font-size:11px; margin:0; padding:0; color:#666;'>Ready. Load an .scn file or mark fragment timestamps.</div>", 1, 17, 12, 1)

    -- Track active context
    app.loaded_video_path = VlcPlayerAdapter.get_video_path()
    app.loaded_scn_path = initial_path

    -- Auto-load if .scn file exists at guessed path
    if initial_path ~= "" then
        local f = io.open(initial_path, "r")
        if f then
            f:close()
            app:on_load_file()
        end
    end
end

function menu()
    return {
        "⏱️ Mark Start",
        "⏱️ Mark End",
        "➕ Add / Save Scene",
        "⏮️ Jump to Start",
        "⏭️ Jump to End",
        "✏️ Edit Selected Scene",
        "✂️ Cut Selected Scene",
        "🗑️ Delete Selected Scene",
        "📄 Export Cut Script"
    }
end

function trigger_menu(id)
    if not app.repo then
        app.repo = SceneRepository.new()
        local initial_path = VlcPlayerAdapter.guess_scn_path()
        if initial_path ~= "" then
            local f = io.open(initial_path, "r")
            if f then
                f:close()
                app.repo:load(initial_path)
            end
        end
    end

    if id == 1 then
        app:on_mark_start()
    elseif id == 2 then
        app:on_mark_end()
    elseif id == 3 then
        app:on_save_scene()
    elseif id == 4 then
        app:on_jump_to_start()
    elseif id == 5 then
        app:on_jump_to_end()
    elseif id == 6 then
        app:on_edit_selected()
    elseif id == 7 then
        app:on_cut_selected()
    elseif id == 8 then
        app:on_delete_selected()
    elseif id == 9 then
        app:on_export_script()
    end
end

function deactivate()
    if app.dlg then
        app.dlg:delete()
    end
    app.dlg = nil
    app.list = nil
    app.workdir_input = nil
    app.path_input = nil
    app.start_input = nil
    app.end_input = nil
    app.title_input = nil
    app.status_box = nil
    app.status_label = nil
    app.editing_scene = nil
    app.editing_scene_id = nil
    app.pending_delete_ids = nil
    app.pending_new_confirm = nil
    app.loaded_video_path = ""
    app.loaded_scn_path = ""
    app.repo = nil
end

function close()
    vlc.deactivate()
end

--------------------------------------------------
-- 10. Test Export Hook (Headless Testing)
--------------------------------------------------
if _G and _G.__TEST__ then
    _G.__TEST_CLASSES__ = {
        TimeCode         = TimeCode,
        Scene            = Scene,
        SceneRepository  = SceneRepository,
        Platform         = Platform,
        CutterService    = CutterService,
        VlcPlayerAdapter = VlcPlayerAdapter,
        app              = app,
        wrap_status_text = wrap_status_text,
        html_escape      = html_escape,
        activate         = activate
    }
end
