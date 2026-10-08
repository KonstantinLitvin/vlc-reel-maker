--------------------------------------------------
-- Domain Entity: Scene
--------------------------------------------------
local TimeCode = require("timecode")
local L = require("locale")

local Scene = {}
Scene.__index = Scene

--- Create a new Scene entity
-- @param id number Scene identifier
-- @param start_tc TimeCode Start timecode
-- @param end_tc TimeCode End timecode
-- @param title string Scene title
-- @param max_duration TimeCode|number Optional media duration ceiling
function Scene.new(id, start_tc, end_tc, title, max_duration)
    if not (start_tc and end_tc) then
        return nil, "Start and End timecodes are required"
    end
    if end_tc <= start_tc then
        return nil, "End timestamp must be strictly greater than start timestamp"
    end

    if max_duration then
        local max_tc = type(max_duration) == "number" and TimeCode.from_seconds(max_duration) or max_duration
        if max_tc then
            if start_tc >= max_tc then
                return nil, string.format("Start timestamp (%s) cannot be greater than or equal to media duration (%s)",
                    start_tc:to_string(true, ","), max_tc:to_string(true, ","))
            end
            if end_tc > max_tc then
                return nil, string.format("End timestamp (%s) exceeds media duration (%s)",
                    end_tc:to_string(true, ","), max_tc:to_string(true, ","))
            end
        end
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

Scene.TABLE_HEADER = L.table_header

function Scene.get_table_header()
    return L.table_header
end

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

return Scene
