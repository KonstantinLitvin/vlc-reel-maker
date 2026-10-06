--------------------------------------------------
-- Domain Entity: Scene
--------------------------------------------------
local TimeCode = require("timecode")

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

return Scene
