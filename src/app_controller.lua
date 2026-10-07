--------------------------------------------------
-- UI Controller & Application State: app
--------------------------------------------------
local TimeCode = require("timecode")
local Scene = require("scene")
local Platform = require("platform")
local CutterService = require("cutter_service")
local SceneRepository = require("scene_repository")
local VlcPlayerAdapter = require("vlc_player_adapter")
local L = require("locale")

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
    media_box          = nil,
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
        table.insert(display_lines, L.status_truncated_log)
    end

    local formatted = table.concat(display_lines, "<br>")
    local html = string.format("<div style='font-family:sans-serif; font-size:13px; margin:0; padding:0; line-height:1.35; word-wrap:break-word; color:%s;'>%s</div>", color, formatted)

    if self.status_box then
        self.status_box:set_text(html)
    end
    if vlc and vlc.msg then
        vlc.msg.dbg("[MediaCutter] " .. msg:gsub("<[^>]+>", ""))
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
    if self.path_input and self.path_input:get_text() and self.path_input:get_text():match("%S") then
        p = self.path_input:get_text()
    elseif self.loaded_scn_path and self.loaded_scn_path ~= "" then
        return self.loaded_scn_path
    end

    local wd = self:get_work_dir()
    local fallback = VlcPlayerAdapter.guess_work_dir()
    if p and p:match("%S") then
        return Platform.resolve_scn(p, wd, fallback)
    end

    local guessed = VlcPlayerAdapter.guess_scn_path()
    if guessed ~= "" then
        local basename = guessed:match("([^\\/]+)$") or guessed
        return Platform.resolve_scn(basename, wd, fallback)
    end

    return ""
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
    self.list:add_value(L.table_header, 0)

    for _, sc in ipairs(self.repo.scenes) do
        self.list:add_value(sc:to_table_row(), sc.id)
    end
end

--- Update active media banner at top of dialog
function app:update_media_display()
    if not self.media_box then return end
    local media_name = (VlcPlayerAdapter.get_media_name and VlcPlayerAdapter.get_media_name()) or ""
    if media_name == "" then
        local video_path = VlcPlayerAdapter.get_video_path()
        if video_path and video_path ~= "" then
            media_name = video_path:match("([^\\/]+)$") or video_path
        end
    end

    local text
    if media_name and media_name ~= "" then
        text = string.format("%s <span style='color:#1976d2; font-weight:bold;'>%s</span>", L.media_header, html_escape(media_name))
    else
        text = string.format("%s <span style='color:#777;'>%s</span>", L.media_header, L.media_none)
    end
    self.media_box:set_text(text)
end

--- Action handler for 'Set Dir' button
function app:on_set_work_dir()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local wd = self:get_work_dir()
    if not wd or wd == "" then
        self:set_status(L.warn_enter_workdir, "warn")
        return
    end

    local ok, was_created = Platform.ensure_dir(wd)
    if not ok then
        self:set_status("❌ " .. tostring(was_created), "error")
        return
    end

    -- Derive .scn filename from media stem
    local guessed = VlcPlayerAdapter.guess_scn_path()
    local scn_filename = "new_scenes.scn"
    if guessed and guessed ~= "" then
        scn_filename = guessed:match("([^\\/]+)$") or guessed
    end

    local target_path = Platform.resolve_scn(scn_filename, wd, wd)
    local action_msg = ""

    local f = io.open(target_path, "r")
    if f then
        f:close()
        -- Exists: load it
        self:cancel_edit()
        local load_ok, res = self.repo:load(target_path)
        if load_ok then
            self.loaded_scn_path = target_path
            self.loaded_video_path = VlcPlayerAdapter.get_video_path()
            self:refresh_list()
            action_msg = string.format(L.status_loaded_scenes, res, scn_filename)
        else
            action_msg = string.format(L.warn_found_load_failed, scn_filename, tostring(res))
        end
    else
        -- Does not exist: create new empty file with media stem
        self:cancel_edit()
        if self.repo then
            self.repo:clear()
        end
        local save_ok, err = self.repo:save(target_path)
        if save_ok then
            self.loaded_scn_path = target_path
            self.loaded_video_path = VlcPlayerAdapter.get_video_path()
            self:refresh_list()
            action_msg = string.format(L.status_created_empty, scn_filename)
        else
            action_msg = string.format(L.err_create_file_failed, tostring(err))
        end
    end

    -- Keep only filename in path_input
    if self.path_input then
        self.path_input:set_text(scn_filename)
    end

    self:update_media_display()

    -- Scan and print available .scn files in the working directory
    local available = Platform.list_scn_files(wd)
    local avail_str = ""
    if #available == 0 then
        avail_str = L.status_avail_files .. ": " .. L.status_avail_none
    else
        avail_str = string.format("%s (%d): %s", L.status_avail_files, #available, table.concat(available, ", "))
    end

    local dir_header = was_created and string.format(L.status_created_dir, wd) or string.format(L.status_set_dir, wd)
    self:set_status(dir_header .. "<br>" .. action_msg .. "<br>" .. avail_str, "success")
end

--- Action handler for 'Set .scn' button
-- If file exists: loads scenes (Load role). If new file: starts fresh empty file (New role).
function app:on_set_scn_file()
    self.pending_delete_ids = nil

    local raw_p = self.path_input and self.path_input:get_text() or ""
    if not raw_p or raw_p:match("^%s*$") then
        self.pending_new_confirm = nil
        self:set_status(L.warn_enter_scn, "warn")
        return
    end

    local resolved_path = self:get_scn_path()
    if not resolved_path or resolved_path == "" then
        self.pending_new_confirm = nil
        self:set_status(L.err_resolve_scn, "error")
        return
    end

    local wd = self:get_work_dir() or VlcPlayerAdapter.guess_work_dir()
    local basename = resolved_path:match("([^\\/]+)$") or resolved_path

    local f = io.open(resolved_path, "r")
    if f then
        f:close()
        self.pending_new_confirm = nil
        self:cancel_edit()
        -- File exists: Load it
        local ok, res = self.repo:load(resolved_path)
        if not ok then
            self:set_status(string.format(L.err_load_file_failed, tostring(res)), "error")
            return
        end
        self.loaded_scn_path = resolved_path
        self.loaded_video_path = VlcPlayerAdapter.get_video_path()
        self:refresh_list()
        self:update_media_display()
        if self.path_input then
            self.path_input:set_text(basename)
        end
        self:set_status(string.format(L.status_set_scn_loaded, res, basename), "success")
    else
        -- File does not exist: Play 'New' role
        if self.repo and self.repo:count() > 0 and not self.pending_new_confirm then
            self.pending_new_confirm = true
            self:set_status(string.format(L.warn_confirm_new_file, self.repo:count(), basename), "warn")
            return
        end
        self.pending_new_confirm = nil

        self:cancel_edit()
        if self.repo then
            self.repo:clear()
        end

        local dir_part = resolved_path:match("^(.*[\\/])")
        if dir_part then
            Platform.ensure_dir(dir_part)
        end

        local ok, err = self.repo:save(resolved_path)
        if not ok then
            self:set_status(string.format(L.err_create_new_scn_failed, tostring(err)), "error")
            return
        end

        self.loaded_scn_path = resolved_path
        self.loaded_video_path = VlcPlayerAdapter.get_video_path()
        self:refresh_list()
        self:update_media_display()
        if self.path_input then
            self.path_input:set_text(basename)
        end
        self:set_status(string.format(L.status_set_scn_created, basename), "success")
    end
end

function app:on_new_file()
    self.pending_delete_ids = nil

    if self.repo and self.repo:count() > 0 and not self.pending_new_confirm then
        self.pending_new_confirm = true
        self:set_status(L.warn_confirm_new_inmem, "warn")
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

    self:set_status(L.status_new_started)
end

function app:on_load_file()
    self:cancel_edit()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local path = self:get_scn_path()
    if not path or path == "" then
        self:set_status(L.warn_enter_valid_scn)
        return
    end

    local f = io.open(path, "r")
    if not f then
        local basename = path:match("([^\\/]+)$") or path
        self:set_status(string.format(L.err_file_not_found, basename), "error")
        return
    end
    f:close()

    local ok, res = self.repo:load(path)
    if not ok then
        self.list:clear()
        self.list:add_value(L.table_header, 0)
        self.list:add_value(L.err_open_file_failed, 1)
        self:set_status(string.format(L.err_load_file_failed, tostring(res)), "error")
        return
    end

    self.loaded_scn_path = path
    self.loaded_video_path = VlcPlayerAdapter.get_video_path()

    self:refresh_list()
    self:update_media_display()
    local basename = path:match("([^\\/]+)$") or path
    self:set_status(string.format(L.status_loaded_scenes, res, basename))
end

function app:on_save_as()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local path = self:get_scn_path()
    if not path or path == "" then
        self:set_status(L.warn_target_scn_req)
        return
    end

    if not self.repo or self.repo:count() == 0 then
        self:set_status(L.warn_no_scenes_to_save, "warn")
        return
    end

    local ok, res = self.repo:save(path)
    if not ok then
        self:set_status(string.format(L.err_save_file_failed, tostring(res)), "error")
        return
    end

    self.loaded_scn_path = path
    self.loaded_video_path = VlcPlayerAdapter.get_video_path()
    self:update_media_display()
    local basename = path:match("([^\\/]+)$") or path
    self:set_status(string.format(L.status_saved_scenes, self.repo:count(), basename))
end

function app:on_mark_start()
    self.pending_new_confirm = nil
    self:update_media_display()
    local tc, err = VlcPlayerAdapter.get_current_time()
    if not tc then
        self:set_status(string.format(L.warn_cannot_mark_start, err))
        return
    end

    if self.start_input then
        self.start_input:set_text(tc:to_string(true, ","))
        self:set_status(string.format(L.status_start_marked, tc:to_string(true, ",")))
    end
end

function app:on_mark_end()
    self.pending_new_confirm = nil
    self:update_media_display()
    local tc, err = VlcPlayerAdapter.get_current_time()
    if not tc then
        self:set_status(string.format(L.warn_cannot_mark_end, err))
        return
    end

    if self.end_input then
        self.end_input:set_text(tc:to_string(true, ","))
        self:set_status(string.format(L.status_end_marked, tc:to_string(true, ",")))
    end
end

function app:on_save_scene()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local path = self:get_scn_path()
    if not path or path == "" then
        self:set_status(L.warn_target_scn_req_single)
        return
    end

    local s_text = self.start_input and self.start_input:get_text() or ""
    local e_text = self.end_input and self.end_input:get_text() or ""
    local title  = self.title_input and self.title_input:get_text() or ""

    local start_tc, s_err = TimeCode.from_string(s_text)
    if not start_tc then
        self:set_status(string.format(L.warn_invalid_start, tostring(s_err)))
        return
    end

    local end_tc, e_err = TimeCode.from_string(e_text)
    if not end_tc then
        self:set_status(string.format(L.warn_invalid_end, tostring(e_err)))
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
            self:set_status(L.warn_scene_edit_cancelled, "warn")
            return
        end

        local ok, res = self.repo:update(target_sc.id, start_tc, end_tc, title)
        if not ok then
            self:set_status("❌ " .. tostring(res))
            return
        end

        local save_ok, save_err = self.repo:save(path)
        if not save_ok then
            self:set_status(string.format(L.warn_updated_mem_failed_save, tostring(save_err)))
        else
            self:set_status(string.format(L.status_scene_updated, res.id, res.title))
        end

        self:cancel_edit()
    else
        if title:match("^%s*$") then
            title = string.format(L.default_scene_title, self.repo:count() + 1)
        end

        local ok, res = self.repo:add(start_tc, end_tc, title)
        if not ok then
            self:set_status("❌ " .. tostring(res))
            return
        end

        local save_ok, save_err = self.repo:save(path)
        if not save_ok then
            self:set_status(string.format(L.warn_added_mem_failed_save, tostring(save_err)))
        else
            self:set_status(string.format(L.status_scene_added, res.id, res.title))
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
    local sc, err = self:get_selected_scene(L.action_edit)
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    -- Toggle edit mode off if already editing this exact scene
    if self.editing_scene == sc or self.editing_scene_id == sc.id then
        self:cancel_edit()
        self:set_status(string.format(L.status_edit_cancelled, sc.id))
        return
    end

    self.editing_scene = sc
    self.editing_scene_id = sc.id
    if self.start_input then self.start_input:set_text(sc.start_tc:to_string(true, ",")) end
    if self.end_input then self.end_input:set_text(sc.end_tc:to_string(true, ",")) end
    if self.title_input then self.title_input:set_text(sc.title) end
    self:set_status(string.format(L.status_editing_scene, sc.id))
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
        return nil, L.err_no_scene_selected
    end

    local scenes = self:get_selected_scenes()
    if #scenes == 0 then
        return nil, L.err_header_row_selected
    elseif #scenes > 1 then
        action_name = action_name or L.action_default
        return nil, string.format(L.err_multi_scene_selected, #scenes, action_name)
    end
    return scenes[1]
end

function app:on_jump_to_start()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local sc, err = self:get_selected_scene(L.action_to_start)
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local ok, seek_err = VlcPlayerAdapter.seek(sc.start_tc)
    if not ok then
        self:set_status("❌ " .. seek_err)
    else
        self:set_status(string.format(L.status_jumped_start, sc.id, sc.start_tc:to_string(true, ",")))
    end
end

function app:on_jump_to_end()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local sc, err = self:get_selected_scene(L.action_to_end)
    if not sc then
        self:set_status("⚠️ " .. err)
        return
    end

    local ok, seek_err = VlcPlayerAdapter.seek(sc.end_tc)
    if not ok then
        self:set_status("❌ " .. seek_err)
    else
        self:set_status(string.format(L.status_jumped_end, sc.id, sc.end_tc:to_string(true, ",")))
    end
end

function app:on_cut_selected()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil
    local scenes = self:get_selected_scenes()
    if #scenes == 0 then
        self:set_status(L.warn_select_scenes_cut, "warn")
        return
    end

    local video_path = VlcPlayerAdapter.get_video_path()
    if not video_path or video_path == "" then
        self:set_status(L.warn_cannot_find_video, "warn")
        return
    end

    -- Video mismatch guard
    if self.loaded_video_path ~= "" and video_path ~= self.loaded_video_path then
        local old_name = self.loaded_video_path:match("([^\\/]+)$") or self.loaded_video_path
        local cur_name = video_path:match("([^\\/]+)$") or video_path
        self:set_status(string.format(L.err_video_mismatch, old_name, cur_name), "error")
        return
    end

    local work_dir = self:get_work_dir()
    local cut_count = 0
    local failed = {}

    for i, sc in ipairs(scenes) do
        if #scenes > 1 then
            self:set_status(string.format(L.status_cutting_progress, i, #scenes, sc.title))
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
        self:set_status(string.format(L.warn_err_cut_batch, cut_count, #scenes, err_summary), "error")
    else
        if #scenes == 1 then
            local sc = scenes[1]
            local out_path = CutterService.derive_output_path(video_path, sc, work_dir)
            local basename = out_path:match("([^\\/]+)$") or out_path
            self:set_status(string.format(L.status_single_cut_complete, sc.id, basename, out_path), "success")
        else
            local target_dir = (work_dir and work_dir ~= "") and work_dir or (video_path:match("^(.*[\\/])") or L.fallback_work_dir)
            self:set_status(string.format(L.status_batch_cut_complete, cut_count, target_dir), "success")
        end
    end
end

function app:on_delete_selected()
    self.pending_new_confirm = nil
    local scenes = self:get_selected_scenes()
    if #scenes == 0 then
        self:set_status(L.warn_select_scenes_delete, "warn")
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
            self:set_status(string.format(L.warn_confirm_del_multi, #ids), "warn")
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
            self:set_status(string.format(L.warn_del_mem_failed_save, res, tostring(save_err)))
        else
            if #scenes == 1 then
                self:set_status(string.format(L.status_deleted_single, scenes[1].id, scenes[1].title))
            else
                self:set_status(string.format(L.status_deleted_multi_reindexed, res))
            end
        end
    else
        if #scenes == 1 then
            self:set_status(string.format(L.status_deleted_single, scenes[1].id, scenes[1].title))
        else
            self:set_status(string.format(L.status_deleted_multi, res))
        end
    end

    self:refresh_list()
end

function app:on_export_script()
    self.pending_delete_ids = nil
    self.pending_new_confirm = nil

    local video_path = VlcPlayerAdapter.get_video_path()
    if not video_path or video_path == "" then
        self:set_status(L.warn_cannot_find_video, "warn")
        return
    end

    if not self.repo or self.repo:count() == 0 then
        self:set_status(L.warn_no_scenes_export, "warn")
        return
    end

    -- Video mismatch guard
    if self.loaded_video_path ~= "" and video_path ~= self.loaded_video_path then
        local old_name = self.loaded_video_path:match("([^\\/]+)$") or self.loaded_video_path
        local cur_name = video_path:match("([^\\/]+)$") or video_path
        self:set_status(string.format(L.err_video_mismatch, old_name, cur_name), "error")
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
    local scn_path = self.loaded_scn_path
    if not scn_path or scn_path == "" then
        scn_path = self:get_scn_path()
    end
    local ok, res = CutterService.export_script(video_path, targets, nil, work_dir, scn_path)
    if not ok then
        self:set_status(string.format(L.err_export_script_failed, tostring(res)), "error")
    else
        local basename = res:match("([^\\/]+)$") or res
        if #targets < self.repo:count() then
            self:set_status(string.format(L.status_script_selected, #targets, basename), "success")
        else
            self:set_status(string.format(L.status_script_exported, #targets, basename), "success")
        end
    end
end

return {
    app = app,
    wrap_status_text = wrap_status_text,
    html_escape = html_escape
}
