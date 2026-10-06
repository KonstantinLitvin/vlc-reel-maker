--------------------------------------------------
-- Value Object: TimeCode
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

return TimeCode
