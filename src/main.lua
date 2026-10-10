--------------------------------------------------
-- Main Entry Point: VLC Lifecycle Hooks & Menu
--------------------------------------------------
local TimeCode = require("timecode")
local Scene = require("scene")
local Platform = require("platform")
local CutterService = require("cutter_service")
local SceneRepository = require("scene_repository")
local VlcPlayerAdapter = require("vlc_player_adapter")
local ui = require("app_controller")
local L = require("locale")
local Version = require("version")

local app = ui.app
local wrap_status_text = ui.wrap_status_text
local html_escape = ui.html_escape

function descriptor()
    local name = (L.ext_title or "ReelMaker") .. " v" .. (Version or "1.2")
    return {
        title        = name,
        version      = Version,
        author       = "Konstantin Litvin",
        shortdesc    = name,
        description  = L.ext_desc,
        capabilities = { "menu" }
    }
end

function activate()
    if app.dlg then return end

    if not app.repo then
        app.repo = SceneRepository.new()
    end
    app.dlg = vlc.dialog(string.format("%s v%s", L.ext_title, Version))

    -- Primary Default Button (Add / Save Scene):
    -- Registered first so Qt QDialog designates it as the dialog's default autoDefault button.
    -- In Qt, pressing Enter in a single-line text input (such as Title) triggers the dialog's
    -- default button, invoking on_save_scene(). Grid coordinates remain at row 16, cols 9-12.
    app.add_save_btn = app.dlg:add_button(Platform.format_btn(L.btn_add_save), function() app:on_save_scene() end, 9, 16, 4, 1, 210, 28)

    -- Row 1: Active Media Banner (Label, full width)
    app.media_box = app.dlg:add_label("", 1, 1, 12, 1, 650, 24)
    app:update_media_display()

    -- Row 2: Working Directory input (Cols 1-9) & Set Dir button (Cols 10-12)
    local initial_work_dir = VlcPlayerAdapter.guess_work_dir()
    app.workdir_input = app.dlg:add_text_input(initial_work_dir, 1, 2, 9, 1, 480, 26)
    app.dlg:add_button(Platform.format_btn(L.btn_set_dir), function() app:on_set_work_dir() end, 10, 2, 3, 1, 150, 26)

    -- Row 3: .scn file input (Cols 1-9) & Set .scn button (Cols 10-12)
    local initial_path = VlcPlayerAdapter.guess_scn_path()
    local initial_filename = initial_path:match("([^\\/]+)$") or initial_path
    app.path_input = app.dlg:add_text_input(initial_filename, 1, 3, 9, 1, 480, 26)
    app.dlg:add_button(Platform.format_btn(L.btn_set_scn), function() app:on_set_scn_file() end, 10, 3, 3, 1, 150, 26)

    -- Rows 4-11: Scenes list view (height 8, full width)
    app.list = app.dlg:add_list(1, 4, 12, 8, 650, 180)
    app.list:add_value(L.table_header, 0)

    -- Row 12: Scene Operations (Navigation, Edit, Delete - 4 equal buttons, span 3 each)
    app.dlg:add_button(Platform.format_btn(L.btn_to_start), function() app:on_jump_to_start() end,    1, 12, 3, 1, 155, 30)
    app.dlg:add_button(Platform.format_btn(L.btn_to_end),   function() app:on_jump_to_end() end,      4, 12, 3, 1, 155, 30)
    app.dlg:add_button(Platform.format_btn(L.btn_edit),     function() app:on_edit_selected() end,    7, 12, 3, 1, 155, 30)
    app.dlg:add_button(Platform.format_btn(L.btn_delete),   function() app:on_delete_selected() end, 10, 12, 3, 1, 155, 30)

    -- Row 13: Production / Output (FFmpeg Actions: Cut & Export Script - 2 equal buttons, span 6 each)
    app.dlg:add_button(Platform.format_btn(L.btn_cut),           function() app:on_cut_selected() end, 1, 13, 6, 1, 315, 32)
    app.dlg:add_button(Platform.format_btn(L.btn_export_script), function() app:on_export_script() end, 7, 13, 6, 1, 315, 32)

    -- Row 14: Fragment Start input & Mark button
    app.dlg:add_label(L.lbl_start, 1, 14, 2, 1)
    app.start_input = app.dlg:add_text_input("", 3, 14, 3, 1, 150, 26)
    app.dlg:add_button(Platform.format_btn(L.btn_mark), function() app:on_mark_start() end, 6, 14, 2, 1, 90, 26)

    -- Row 15: Fragment End input & Mark button
    app.dlg:add_label(L.lbl_end, 1, 15, 2, 1)
    app.end_input = app.dlg:add_text_input("", 3, 15, 3, 1, 150, 26)
    app.dlg:add_button(Platform.format_btn(L.btn_mark), function() app:on_mark_end() end, 6, 15, 2, 1, 90, 26)

    -- Row 16: Scene Title input (Add/Save button registered above as primary default button)
    app.dlg:add_label(L.lbl_title, 1, 16, 2, 1)
    app.title_input = app.dlg:add_text_input("", 3, 16, 6, 1, 315, 26)

    -- Row 17: Fixed-height Scrollable & Copyable Status Area (height ~75px, 2-3 lines)
    local available = Platform.list_scn_files(initial_work_dir)
    local avail_str = #available > 0 and ("<br>" .. L.status_avail_files .. " (" .. #available .. "): " .. table.concat(available, ", ")) or ""
    app.status_box = app.dlg:add_html("<div style='font-family:sans-serif; font-size:13px; color:#555;'>" .. L.status_ready .. avail_str .. "</div>", 1, 17, 12, 1, 650, 75)

    -- Track active context
    app.loaded_video_path = VlcPlayerAdapter.get_video_path()
    app.loaded_scn_path = initial_path

    -- Auto-load if .scn file exists at guessed path
    if initial_path ~= "" then
        local f = io.open(initial_path, "r")
        if f then
            f:close()
            local ok, res = app.repo:load(initial_path)
            if ok then
                app:refresh_list()
                local files_str = #available > 0 and ("<br>" .. L.status_avail_files .. " (" .. #available .. "): " .. table.concat(available, ", ")) or ""
                app:set_status(string.format(L.status_loaded_scenes .. "%s", res, initial_filename, files_str), "success")
            end
        end
    end
end

function menu()
    return {
        L.menu_mark_start,
        L.menu_mark_end,
        L.menu_add_save,
        L.menu_jump_start,
        L.menu_jump_end,
        L.menu_edit,
        L.menu_cut,
        L.menu_delete,
        L.menu_export_script
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
    app.media_box = nil
    app.workdir_input = nil
    app.path_input = nil
    app.start_input = nil
    app.end_input = nil
    app.title_input = nil
    app.status_box = nil
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
-- Test Export Hook (Headless Testing)
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
        truncate_middle  = ui.truncate_middle,
        activate         = activate
    }
end

return {
    descriptor   = descriptor,
    activate     = activate,
    menu         = menu,
    trigger_menu = trigger_menu,
    deactivate   = deactivate,
    close        = close
}
