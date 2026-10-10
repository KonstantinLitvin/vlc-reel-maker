--------------------------------------------------
-- Infrastructure Port: VlcPlayerAdapter
--------------------------------------------------
local TimeCode = require("timecode")

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

--- Query active media duration
-- @return TimeCode, error_message
function VlcPlayerAdapter.get_media_duration()
    if not vlc then return nil, "VLC runtime not available" end

    -- Strategy 1: vlc.input.item():duration() (returns seconds as float/int)
    if vlc.input and vlc.input.item then
        local item = vlc.input.item()
        if item and item.duration then
            local sec = item:duration()
            if sec and sec > 0 then
                return TimeCode.from_seconds(sec)
            end
        end
    end

    -- Strategy 2: vlc.var.get(input, "length") (returns microseconds)
    if vlc.object and vlc.object.input and vlc.var and vlc.var.get then
        local input = vlc.object.input()
        if input then
            local us = vlc.var.get(input, "length")
            if us and us > 0 then
                return TimeCode.from_seconds(us / 1000000)
            end
        end
    end

    return nil, "Media duration unavailable"
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

    -- Windows path normalization (e.g. /C:/... or UNC //vmware-host/...)
    local is_win = (package and package.config and package.config:sub(1, 1) == "\\") or false
    if is_win then
        if path:match("^/[a-zA-Z]:") then
            path = path:sub(2)
        elseif path:match("^///+") then
            path = path:gsub("^///+", "//")
        elseif not path:match("^[a-zA-Z]:") and not path:match("^[\\/]") then
            path = "//" .. path
        end
        path = path:gsub("/", "\\")
    else
        if path:match("^/[a-zA-Z]:") then
            path = path:sub(2)
        end
    end
    return path
end

--- Get media display name (title or filename) from playing item
function VlcPlayerAdapter.get_media_name()
    if not vlc or not vlc.input or not vlc.input.item then return "" end
    local item = vlc.input.item()
    if not item then return "" end

    if item.name then
        local name = item:name()
        if name and name ~= "" then return name end
    end

    local path = VlcPlayerAdapter.get_video_path()
    if path and path ~= "" then
        return path:match("([^\\/]+)$") or path
    end
    return ""
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

return VlcPlayerAdapter
