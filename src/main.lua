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

local app = ui.app
local wrap_status_text = ui.wrap_status_text
local html_escape = ui.html_escape

function descriptor()
    return {
        title        = "Scene Marker",
        version      = "1.2",
        author       = "Konstantin Litvin & Antigravity",
        shortdesc    = "Fragment capture, scene navigation & cutting",
        description  = "Mark fragment start and end timestamps, export/cut via FFmpeg, save directly to .scn files, and navigate scenes.",
        capabilities = { "menu" }
    }
end

function activate()
    if app.dlg then return end

    if not app.repo then
        app.repo = SceneRepository.new()
    end
    app.dlg = vlc.dialog("Scene Marker")

    -- Row 1: File Actions (New, Load, Save As - 3 equal buttons, span 4 each)
    app.dlg:add_button("📄 New",     function() app:on_new_file() end,  1, 1, 4, 1)
    app.dlg:add_button("📂 Load",    function() app:on_load_file() end, 5, 1, 4, 1)
    app.dlg:add_button("💾 Save As", function() app:on_save_as() end,   9, 1, 4, 1)

    -- Row 2: Working Directory input & Set Dir button
    app.dlg:add_label("<b>Work Dir:</b>", 1, 2, 2, 1)
    local initial_work_dir = VlcPlayerAdapter.guess_work_dir()
    app.workdir_input = app.dlg:add_text_input(initial_work_dir, 3, 2, 7, 1)
    app.dlg:add_button("📁 Set Dir", function() app:on_set_work_dir() end, 10, 2, 3, 1)

    -- Row 3: .scn Files dropdown & Select button
    app.dlg:add_label("<b>.scn Files:</b>", 1, 3, 2, 1)
    app.scn_dropdown = app.dlg:add_dropdown(3, 3, 7, 1)
    app.dlg:add_button("📋 Select", function() app:on_select_from_dropdown() end, 10, 3, 3, 1)

    -- Row 4: .scn file input (relative filename if inside work directory)
    app.dlg:add_label("<b>.scn File:</b>", 1, 4, 2, 1)
    local initial_path = VlcPlayerAdapter.guess_scn_path()
    local initial_display = Platform.relative_display(initial_path, initial_work_dir)
    app.path_input = app.dlg:add_text_input(initial_display, 3, 4, 10, 1)

    -- Populate dropdown with discovered .scn files in work directory
    app:scan_and_populate_dropdown(initial_work_dir)

    -- Rows 5-12: Scenes list view (height 8, full width)
    app.list = app.dlg:add_list(1, 5, 12, 8)
    app.list:add_value(Scene.TABLE_HEADER, 0)

    -- Row 13: Scene Operations (Navigation, Edit, Delete - 4 equal buttons, span 3 each)
    app.dlg:add_button("⏮️ To Start", function() app:on_jump_to_start() end,    1, 13, 3, 1)
    app.dlg:add_button("⏭️ To End",   function() app:on_jump_to_end() end,      4, 13, 3, 1)
    app.dlg:add_button("✏️ Edit",     function() app:on_edit_selected() end,    7, 13, 3, 1)
    app.dlg:add_button("🗑️ Delete",   function() app:on_delete_selected() end, 10, 13, 3, 1)

    -- Row 14: Production / Output (FFmpeg Actions: Cut & Export Script - 2 equal buttons, span 6 each)
    app.dlg:add_button("✂️ Cut",             function() app:on_cut_selected() end, 1, 14, 6, 1)
    app.dlg:add_button("🎬 Export Cut Script", function() app:on_export_script() end, 7, 14, 6, 1)

    -- Row 15: Fragment Start input & Mark button
    app.dlg:add_label("<b>Start:</b>", 1, 15, 2, 1)
    app.start_input = app.dlg:add_text_input("", 3, 15, 3, 1)
    app.dlg:add_button("⏱️ Mark", function() app:on_mark_start() end, 6, 15, 2, 1)

    -- Row 16: Fragment End input & Mark button
    app.dlg:add_label("<b>End:</b>", 1, 16, 2, 1)
    app.end_input = app.dlg:add_text_input("", 3, 16, 3, 1)
    app.dlg:add_button("⏱️ Mark", function() app:on_mark_end() end, 6, 16, 2, 1)

    -- Row 17: Scene Title input & Add/Save Scene button
    app.dlg:add_label("<b>Title:</b>", 1, 17, 2, 1)
    app.title_input = app.dlg:add_text_input("", 3, 17, 6, 1)
    app.dlg:add_button("➕ Add / Save Scene", function() app:on_save_scene() end, 9, 17, 4, 1)

    -- Row 18: Fixed-height Scrollable & Copyable Status Area (QTextBrowser, height ~75-80px / ~4 lines, scrollbar as needed)
    app.status_box = app.dlg:add_html("<div style='font-family:sans-serif; font-size:11px; margin:0; padding:0; color:#666;'>Ready. Load an .scn file or mark fragment timestamps.</div>", 1, 18, 12, 1)

    -- Track active context
    app.loaded_video_path = VlcPlayerAdapter.get_video_path()
    app.loaded_scn_path = initial_path

    -- Auto-load if .scn file exists at guessed path
    if initial_path ~= "" then
        local f = io.open(initial_path, "r")
        if f then
            f:close()
            app:on_load_file()
        end
    end
end

function menu()
    return {
        "⏱️ Mark Start",
        "⏱️ Mark End",
        "➕ Add / Save Scene",
        "⏮️ Jump to Start",
        "⏭️ Jump to End",
        "✏️ Edit Selected Scene",
        "✂️ Cut Selected Scene",
        "🗑️ Delete Selected Scene",
        "📄 Export Cut Script"
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
    app.workdir_input = nil
    app.scn_dropdown = nil
    app.dropdown_files = {}
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
