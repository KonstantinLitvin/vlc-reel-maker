--------------------------------------------------
-- Infrastructure: Platform Abstraction
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

--- Check if a directory exists on disk
-- @param dir string Directory path
-- @param is_win boolean Optional override for testing
-- @return boolean True if directory exists
function Platform.dir_exists(dir, is_win)
    if not dir or dir:match("^%s*$") then return false end
    dir = dir:match("^%s*(.-)%s*$")
    if is_win == nil then is_win = Platform.is_windows end

    if is_win then
        local win_dir = dir:gsub("/", "\\"):gsub("\\+$", "")
        local cmd = 'if exist ' .. Platform.quote(win_dir .. "\\*", true) .. ' (exit 0) else (exit 1)'
        if os and os.execute then
            local code = os.execute(cmd)
            return (code == 0 or code == true)
        end
    else
        local posix_dir = dir:gsub("/+$", "")
        local cmd = 'test -d ' .. Platform.quote(posix_dir, false) .. ' 2>/dev/null'
        if os and os.execute then
            local code = os.execute(cmd)
            return (code == 0 or code == true)
        end
    end
    return false
end

--- Ensure a directory exists on disk, creating parent directories if necessary
-- @param dir string Directory path
-- @param is_win boolean Optional override for testing
-- @return boolean, boolean|string ok, was_created_or_err
function Platform.ensure_dir(dir, is_win)
    if not dir or dir:match("^%s*$") then
        return false, "Directory path is required"
    end
    dir = dir:match("^%s*(.-)%s*$")
    if is_win == nil then is_win = Platform.is_windows end

    local already_exists = Platform.dir_exists(dir, is_win)
    if already_exists then
        return true, false -- ok, already existed
    end

    local cmd
    if is_win then
        local win_dir = dir:gsub("/", "\\"):gsub("\\+$", "")
        cmd = 'if not exist ' .. Platform.quote(win_dir, true) .. ' mkdir ' .. Platform.quote(win_dir, true)
    else
        local posix_dir = dir:gsub("/+$", "")
        cmd = 'mkdir -p -- ' .. Platform.quote(posix_dir, false) .. ' 2>/dev/null'
    end

    if not (os and os.execute) then
        return false, "os.execute is unavailable in this Lua environment"
    end

    local code = os.execute(cmd)
    local success = (code == 0 or code == true)
    if not success then
        return false, "Failed to create directory: " .. dir
    end

    return true, true -- ok, was newly created
end

--- List all .scn files in the specified directory, sorted alphabetically
-- @param dir string Directory path
-- @param is_win boolean Optional override for testing
-- @return table Array of .scn filenames (relative to dir)
function Platform.list_scn_files(dir, is_win)
    if not dir or dir:match("^%s*$") then return {} end
    dir = dir:match("^%s*(.-)%s*$")
    if is_win == nil then is_win = Platform.is_windows end

    local cmd
    if is_win then
        local win_dir = dir:gsub("/", "\\")
        if not win_dir:match("\\$") then win_dir = win_dir .. "\\" end
        cmd = 'dir /b /a-d ' .. Platform.quote(win_dir .. "*.scn", true) .. ' 2>nul'
    else
        cmd = 'ls -1A -- ' .. Platform.quote(dir, false) .. ' 2>/dev/null'
    end

    local files = {}
    local p = io.popen(cmd)
    if p then
        for line in p:lines() do
            line = line:match("^%s*(.-)%s*$")
            if line:match("%.[sS][cC][nN]$") then
                table.insert(files, line)
            end
        end
        p:close()
    end
    table.sort(files)
    return files
end

return Platform
