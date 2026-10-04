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
        version      = "1.1",
        author       = "Konstantin Litvin & Antigravity",
        shortdesc    = "Fragment capture, scene navigation & cutting",
        description  = "Mark fragment start and end timestamps, export/cut via FFmpeg, save directly to .scn files, and navigate scenes.",
        capabilities = {}
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
    local h, m, s, sep, ms = str:match("^%s*(%d+):(%d+):(%d+)([,.]?)(%d*)%s*$")
    if not (h and m and s) then
        return nil, "Invalid format (expected HH:MM:SS or HH:MM:SS,mmm)"
    end

    local sec = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
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

function Scene:to_table_row()
    return string.format(
        "%-4d %-12s %-12s %-30s",
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

--- Get script extension for current platform
-- @param is_win boolean Optional override for testing
function Platform.script_ext(is_win)
    if is_win == nil then is_win = Platform.is_windows end
    return is_win and ".bat" or ".sh"
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

--- Derive output fragment filename from video path and scene
function CutterService.derive_output_path(video_path, scene)
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
function CutterService.build_cut_command(video_path, scene, output_path, is_win, ffmpeg_bin)
    local bin = ffmpeg_bin or "ffmpeg"
    local start_str = scene.start_tc:to_string(true, ".")
    local end_str   = scene.end_tc:to_string(true, ".")
    output_path = output_path or CutterService.derive_output_path(video_path, scene)

    local q_bin = Platform.quote(bin, is_win)
    local q_in  = Platform.quote(video_path, is_win)
    local q_out = Platform.quote(output_path, is_win)

    return string.format("%s -y -ss %s -to %s -i %s -c copy %s", q_bin, start_str, end_str, q_in, q_out)
end

--- Generate complete batch cut script for all scenes
function CutterService.generate_script(video_path, scenes, is_win)
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
            local out_path = CutterService.derive_output_path(video_path, sc)
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
            local out_path = CutterService.derive_output_path(video_path, sc)
            table.insert(lines, string.format('echo "Cutting Scene %d: %s..."', sc.id, sc.title))
            table.insert(lines, CutterService.build_cut_command(video_path, sc, out_path, false, "ffmpeg"))
            table.insert(lines, "")
        end

        table.insert(lines, 'echo "All scenes cut successfully!"')
    end

    return table.concat(lines, "\n") .. "\n"
end

--- Export batch script to disk
function CutterService.export_script(video_path, scenes, is_win)
    if not video_path or video_path == "" then
        return false, "Video path is required to export cut script"
    end
    if not scenes or #scenes == 0 then
        return false, "No scenes available to export"
    end

    local ext = Platform.script_ext(is_win)
    local script_path = video_path:gsub("%.[^%.\\/]+$", "") .. "_cut_scenes" .. ext
    local script_content = CutterService.generate_script(video_path, scenes, is_win)

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

--- Execute async cut for single scene without locking VLC UI
function CutterService.cut_scene_async(video_path, scene, is_win)
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

    local out_path = CutterService.derive_output_path(video_path, scene)
    local raw_cmd = CutterService.build_cut_command(video_path, scene, out_path, is_win, bin_or_err)
    local bg_cmd = Platform.bg_command(raw_cmd, nil, is_win)

    if os and os.execute then
        local code = os.execute(bg_cmd)
        return true, out_path
    else
        return false, "os.execute is unavailable in this Lua environment"
    end
end

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
local app = {
    repo         = nil,
    dlg          = nil,
    path_input   = nil,
    list         = nil,
    start_input  = nil,
    end_input    = nil,
    title_input  = nil,
    status_label = nil
}

function app:set_status(msg)
    if self.status_label then
        self.status_label:set_text(msg)
    end
    if vlc and vlc.msg then
        vlc.msg.dbg("[SceneMarker] " .. msg)
    end
end

function app:refresh_list()
    if not self.list then return end
    self.list:clear()
    self.list:add_value(string.format("%-4s %-12s %-12s %-30s", "ID", "Start", "End", "Title"), 0)

    for _, sc in ipairs(self.repo.scenes) do
        self.list:add_value(sc:to_table_row(), sc.id)
    end
end

function app:on_load_file()
    if not self.path_input then return end
    local path = self.path_input:get_text()
    if not path or path:match("^%s*$") then
        self:set_status("⚠️ Please enter a valid .scn file path.")
        return
    end

    local ok, res = self.repo:load(path)
    if not ok then
        self.list:clear()
        self.list:add_value(string.format("%-4s %-12s %-12s %-30s", "ID", "Start", "End", "Title"), 0)
        self.list:add_value("Could not open file.", 1)
        self:set_status("❌ " .. tostring(res))
        return
    end

    self:refresh_list()
    self:set_status(string.format("✅ Loaded %d scene(s) from .scn file.", res))
end

function app:on_mark_start()
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

function app:on_add_scene()
    if not (self.start_input and self.end_input and self.path_input) then return end

    local s_text = self.start_input:get_text()
    local e_text = self.end_input:get_text()
    local title  = self.title_input and self.title_input:get_text() or ""
    local path   = self.path_input:get_text()

    if not path or path:match("^%s*$") then
        self:set_status("⚠️ Target .scn file path is required to save scene.")
        return
    end

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

    self:refresh_list()

    -- Reset fragment inputs for next capture
    self.start_input:set_text("")
    self.end_input:set_text("")
    if self.title_input then self.title_input:set_text("") end
end

function app:get_selected_scene()
    if not self.list then return nil end
    local sel = self.list:get_selection()
    if not sel or next(sel) == nil then
        return nil, "No scene selected from the list"
    end

    local selected_id = next(sel)
    if selected_id == 0 then
        return nil, "Header row selected; please select a scene row"
    end

    local sc = self.repo:get_by_id(selected_id)
    if not sc then
        return nil, "Scene not found for ID: " .. tostring(selected_id)
    end
    return sc
end

function app:on_jump_to_start()
    local sc, err = self:get_selected_scene()
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local ok, seek_err = VlcPlayerAdapter.seek(sc.start_tc)
    if not ok then
        self:set_status("❌ " .. seek_err)
    else
        self:set_status(string.format("▶ Jumped to Scene %d Start: %s", sc.id, sc.start_tc:to_string(true, ",")))
    end
end

function app:on_jump_to_end()
    local sc, err = self:get_selected_scene()
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local ok, seek_err = VlcPlayerAdapter.seek(sc.end_tc)
    if not ok then
        self:set_status("❌ " .. seek_err)
    else
        self:set_status(string.format("⏹ Jumped to Scene %d End: %s", sc.id, sc.end_tc:to_string(true, ",")))
    end
end

function app:on_cut_selected()
    local sc, err = self:get_selected_scene()
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local video_path = VlcPlayerAdapter.get_video_path()
    if not video_path or video_path == "" then
        self:set_status("⚠️ Cannot determine playing video file path")
        return
    end

    local ok, res = CutterService.cut_scene_async(video_path, sc)
    if not ok then
        self:set_status("❌ Cut failed: " .. tostring(res))
    else
        self:set_status(string.format("✂️ Cutting Scene %d in background: %s", sc.id, res))
    end
end

function app:on_export_script()
    local video_path = VlcPlayerAdapter.get_video_path()
    if not video_path or video_path == "" then
        self:set_status("⚠️ Cannot determine playing video file path")
        return
    end

    if self.repo:count() == 0 then
        self:set_status("⚠️ No scenes to export into script")
        return
    end

    local ok, res = CutterService.export_script(video_path, self.repo.scenes)
    if not ok then
        self:set_status("❌ Export script failed: " .. tostring(res))
    else
        self:set_status("📄 Batch cut script exported: " .. res)
    end
end

--------------------------------------------------
-- 9. VLC Extension Lifecycle Hooks
--------------------------------------------------
function activate()
    if app.dlg then return end

    app.repo = SceneRepository.new()
    app.dlg = vlc.dialog("Scene Marker")

    -- Row 1: Actions & Navigation
    app.dlg:add_button("Load .scn File",   function() app:on_load_file() end,      1, 1, 2, 1)
    app.dlg:add_button("▶ Jump to Start",  function() app:on_jump_to_start() end,  3, 1, 1, 1)
    app.dlg:add_button("⏹ Jump to End",    function() app:on_jump_to_end() end,    4, 1, 1, 1)
    app.dlg:add_button("Close",            close,                                 5, 1, 1, 1)

    -- Row 2: File path label
    app.dlg:add_label("<i>Type or paste the path to your .scn file below:</i>", 1, 2, 5, 1)

    -- Row 3: File path input
    local initial_path = VlcPlayerAdapter.guess_scn_path()
    app.path_input = app.dlg:add_text_input(initial_path, 1, 3, 5, 1)

    -- Rows 4-11: Scenes list view (height 8)
    app.list = app.dlg:add_list(1, 4, 5, 8)
    app.list:add_value(string.format("%-4s %-12s %-12s %-30s", "ID", "Start", "End", "Title"), 0)

    -- Row 12: Fragment Start input & Mark Start button
    app.dlg:add_label("<b>Start:</b>", 1, 12, 1, 1)
    app.start_input = app.dlg:add_text_input("", 2, 12, 2, 1)
    app.dlg:add_button("⏱️ Mark Start (In)", function() app:on_mark_start() end, 4, 12, 2, 1)

    -- Row 13: Fragment End input & Mark End button
    app.dlg:add_label("<b>End:</b>", 1, 13, 1, 1)
    app.end_input = app.dlg:add_text_input("", 2, 13, 2, 1)
    app.dlg:add_button("⏱️ Mark End (Out)", function() app:on_mark_end() end, 4, 13, 2, 1)

    -- Row 14: Scene Title input & Add Scene button
    app.dlg:add_label("<b>Title:</b>", 1, 14, 1, 1)
    app.title_input = app.dlg:add_text_input("", 2, 14, 2, 1)
    app.dlg:add_button("➕ Add & Save Scene", function() app:on_add_scene() end, 4, 14, 2, 1)

    -- Row 15: FFmpeg Cutting Actions
    app.dlg:add_button("✂️ Cut Selected Scene", function() app:on_cut_selected() end, 1, 15, 2, 1)
    app.dlg:add_button("📄 Export Cut Script",   function() app:on_export_script() end, 3, 15, 3, 1)

    -- Row 16: Status label
    app.status_label = app.dlg:add_label("Ready. Load an .scn file or mark fragment timestamps.", 1, 16, 5, 1)

    -- Auto-load if .scn file exists at guessed path
    if initial_path ~= "" then
        local f = io.open(initial_path, "r")
        if f then
            f:close()
            app:on_load_file()
        end
    end
end

function deactivate()
    if app.dlg then
        app.dlg:delete()
    end
    app.dlg = nil
    app.list = nil
    app.path_input = nil
    app.start_input = nil
    app.end_input = nil
    app.title_input = nil
    app.status_label = nil
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
        app              = app
    }
end
