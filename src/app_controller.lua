--------------------------------------------------
-- UI Controller & Application State: app
--------------------------------------------------
local TimeCode = require("timecode")
local Scene = require("scene")
local Platform = require("platform")
local CutterService = require("cutter_service")
local SceneRepository = require("scene_repository")
local VlcPlayerAdapter = require("vlc_player_adapter")

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
    scn_dropdown       = nil,
    dropdown_files     = {},
    path_input         = nil,
    list               = nil,
    start_input        = nil,
    end_input          = nil,
    title_input        = nil,
    status_box         = nil,
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
    local p = ""
    if self.path_input then
        p = self.path_input:get_text() or ""
    end

    -- If path_input is empty, check if a file is selected in dropdown
    if (not p or p:match("^%s*$")) and self.scn_dropdown and self.dropdown_files then
        local sel_id = self.scn_dropdown:get_value()
        local n = tonumber(sel_id)
        if n and self.dropdown_files[n] then
            p = self.dropdown_files[n]
        end
    end

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

--- Scan working directory for .scn files and update the dropdown widget
-- @param dir string Directory path to scan
-- @return number Count of .scn files found
function app:scan_and_populate_dropdown(dir)
    if not self.scn_dropdown then return 0 end
    self.scn_dropdown:clear()
    self.dropdown_files = {}

    if not dir or dir == "" then
        self.scn_dropdown:add_value("(No directory set)", 0)
        return 0
    end

    local files = Platform.list_scn_files(dir)
    if #files == 0 then
        self.scn_dropdown:add_value("(No .scn files found)", 0)
        return 0
    end

    for i, file in ipairs(files) do
        self.dropdown_files[i] = file
        self.scn_dropdown:add_value(file, i)
    end
    return #files
end

--- Action handler for 'Set Dir' button
function app:on_set_work_dir()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local wd = self:get_work_dir()
    if not wd or wd == "" then
        self:set_status("⚠️ Please enter a working directory path.", "warn")
        return
    end

    local ok, was_created = Platform.ensure_dir(wd)
    if not ok then
        self:set_status("❌ " .. tostring(was_created), "error")
        return
    end

    local count = self:scan_and_populate_dropdown(wd)
    if was_created then
        self:set_status(string.format("📁 ✨ Created new directory & set Work Dir: %s (%d .scn files)", wd, count), "success")
    else
        self:set_status(string.format("📁 Set Work Dir: %s (Found %d .scn file%s)", wd, count, count == 1 and "" or "s"))
    end
end

--- Action handler for 'Select' dropdown button
function app:on_select_from_dropdown()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    if not self.scn_dropdown or not self.dropdown_files then return end
    local sel_id = self.scn_dropdown:get_value()
    local n = tonumber(sel_id)
    local selected_file = n and self.dropdown_files[n]

    if not selected_file or selected_file == "" then
        self:set_status("⚠️ No valid .scn file selected in dropdown.", "warn")
        return
    end

    if self.path_input then
        self.path_input:set_text(selected_file)
    end
    self:set_status(string.format("📋 Selected: %s. Click 'Load' to open scenes.", selected_file))
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

    -- Refresh dropdown to show newly saved file
    local wd = self:get_work_dir()
    if wd and wd ~= "" then
        self:scan_and_populate_dropdown(wd)
    end
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
            local target_dir = (work_dir and work_dir ~= "") and work_dir or (video_path:match("^(.*[\\/])") or "working directory")
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

return {
    app = app,
    wrap_status_text = wrap_status_text,
    html_escape = html_escape
}
