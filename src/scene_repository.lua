--------------------------------------------------
-- Repository: SceneRepository
--------------------------------------------------
local TimeCode = require("timecode")
local Scene = require("scene")

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
-- @param max_duration TimeCode|number Optional duration ceiling
function SceneRepository:add(start_tc, end_tc, title, max_duration)
    local sc, err = Scene.new(#self.scenes + 1, start_tc, end_tc, title, max_duration)
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
-- @param max_duration TimeCode|number Optional duration ceiling
-- @return boolean, Scene|string ok, updated_scene_or_error
function SceneRepository:update(id, start_tc, end_tc, title, max_duration)
    local sc = self:get_by_id(id)
    if not sc then
        return false, "Scene not found for ID: " .. tostring(id)
    end

    local valid, err = Scene.new(id, start_tc, end_tc, title or sc.title, max_duration)
    if not valid then
        return false, err
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

return SceneRepository
