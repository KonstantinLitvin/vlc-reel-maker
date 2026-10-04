-- Unit test suite for scene-marker.lua
_G.__TEST__ = true

-- Mock VLC runtime environment for headless testing
_G.vlc = {
    msg = {
        dbg  = function(m) end,
        err  = function(m) end,
        info = function(m) end,
        warn = function(m) end
    },
    object = {
        input = function() return "mock_input_handle" end
    },
    var = {
        get = function(input, var)
            if var == "time" then
                -- 75.45 seconds = 00:01:15,450 (75,450,000 microseconds)
                return 75450000
            end
            return nil
        end,
        set = function(input, var, val) end
    },
    input = {
        seek = function(sec) end,
        item = function()
            return {
                uri = function() return "file:///home/user/Videos/sample_movie.mp4" end
            }
        end
    },
    strings = {
        decode_uri = function(u) return u end
    },
    dialog = function(title)
        return {
            add_button = function() return {} end,
            add_label  = function() return { set_text = function() end } end,
            add_html   = function(text)
                local val = text or ""
                return {
                    get_text = function() return val end,
                    set_text = function(self, t) val = t end
                }
            end,
            add_text_input = function(text)
                local val = text or ""
                return {
                    get_text = function() return val end,
                    set_text = function(t) val = t end
                }
            end,
            add_list = function()
                local items = {}
                return {
                    clear = function() items = {} end,
                    add_value = function(self, str, id) items[id] = str end,
                    get_selection = function() return { [1] = items[1] } end
                }
            end,
            delete = function() end
        }
    end,
    deactivate = function() end
}

-- Load target script
local script_path = "src/scene-marker.lua"
local chunk, load_err = loadfile(script_path)
if not chunk then
    -- Fallback if run from tests directory
    chunk, load_err = loadfile("../src/scene-marker.lua")
end
assert(chunk, "Failed to load script: " .. tostring(load_err))
chunk()

local T = _G.__TEST_CLASSES__
assert(T, "Test classes hook not exported from scene-marker.lua")

local TimeCode        = T.TimeCode
local Scene           = T.Scene
local SceneRepository = T.SceneRepository
local Platform        = T.Platform
local CutterService   = T.CutterService
local VlcPlayerAdapter = T.VlcPlayerAdapter

local total_tests = 0
local passed_tests = 0

local function test(name, fn)
    total_tests = total_tests + 1
    local ok, err = pcall(fn)
    if ok then
        passed_tests = passed_tests + 1
        print("  ✓ " .. name)
    else
        print("  ✗ " .. name)
        print("    Error: " .. tostring(err))
    end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s (expected: %s, got: %s)", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or "Condition expected to be true", 2)
    end
end

print("--------------------------------------------------")
print("Running Scene Marker Test Suite (Unit & System)")
print("--------------------------------------------------")

-- 1. TimeCode tests
test("TimeCode.from_seconds and to_string formatting", function()
    local tc = TimeCode.from_seconds(3661.5)
    assert_eq(tc:to_string(true, ","), "01:01:01,500", "With comma ms")
    assert_eq(tc:to_string(true, "."), "01:01:01.500", "With dot ms for ffmpeg")
    assert_eq(tc:to_string(false), "01:01:01", "Without ms")
end)

test("TimeCode.from_string (comma milliseconds)", function()
    local tc, err = TimeCode.from_string("00:02:15,750")
    assert_true(tc ~= nil, "Should parse comma ms: " .. tostring(err))
    assert_eq(tc.total_sec, 135.75, "Total seconds correct")
end)

test("TimeCode.from_string (dot milliseconds)", function()
    local tc, err = TimeCode.from_string("01:10:05.120")
    assert_true(tc ~= nil, "Should parse dot ms: " .. tostring(err))
    assert_eq(tc.total_sec, 4205.12, "Total seconds correct")
end)

test("TimeCode.from_string (no milliseconds)", function()
    local tc, err = TimeCode.from_string("00:00:45")
    assert_true(tc ~= nil, "Should parse without ms: " .. tostring(err))
    assert_eq(tc.total_sec, 45, "Total seconds correct")
end)

test("TimeCode comparison operators (<, <=, ==)", function()
    local t1 = TimeCode.from_seconds(10.0)
    local t2 = TimeCode.from_seconds(20.0)
    local t3 = TimeCode.from_seconds(10.0001)

    assert_true(t1 < t2, "t1 < t2")
    assert_true(t1 <= t2, "t1 <= t2")
    assert_true(t1 == t3, "t1 == t3 within epsilon")
    assert_true(not (t2 < t1), "not t2 < t1")
end)

-- 2. Scene entity tests
test("Scene.new valid construction and duration", function()
    local s_tc = TimeCode.from_seconds(10)
    local e_tc = TimeCode.from_seconds(25.5)
    local sc, err = Scene.new(1, s_tc, e_tc, "Opening Scene")
    assert_true(sc ~= nil, "Scene should be created: " .. tostring(err))
    assert_eq(sc.id, 1, "ID matches")
    assert_eq(sc.title, "Opening Scene", "Title matches")
    assert_eq(sc:duration(), 15.5, "Duration matches")
end)

test("Scene.new invalid end <= start rejected", function()
    local s_tc = TimeCode.from_seconds(50)
    local e_tc = TimeCode.from_seconds(30)
    local sc, err = Scene.new(1, s_tc, e_tc, "Invalid Scene")
    assert_true(sc == nil, "Should reject end <= start")
end)

test("Scene:to_scn_block formatting", function()
    local sc = Scene.new(2, TimeCode.from_seconds(60), TimeCode.from_seconds(120.5), "Dialogue")
    local block = sc:to_scn_block()
    local expected = "2\n00:01:00,000 --> 00:02:00,500\nDialogue"
    assert_eq(block, expected, "SCN block matches specification")
end)

test("Scene.TABLE_HEADER and Scene:to_table_row formatting", function()
    assert_true(Scene.TABLE_HEADER ~= nil, "TABLE_HEADER constant exists")
    assert_eq(Scene.TABLE_HEADER, "ID   Start                   End                     Title", "TABLE_HEADER content matches")
    local sc = Scene.new(1, TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Intro")
    local row = sc:to_table_row()
    assert_eq(row, "1     00:00:10,000   00:00:20,000   Intro", "Row format matches calibrated layout")
end)

-- 3. SceneRepository tests
test("SceneRepository: load, sort out-of-order, reindex, save", function()
    local tmp_path = "/tmp/test_repo_" .. tostring(os.time()) .. ".scn"
    local raw_data = "1\n00:05:00,000 --> 00:06:00,000\nLater Scene\n\n2\n00:01:00,000 --> 00:02:00,000\nEarlier Scene\n"

    local f = assert(io.open(tmp_path, "w"))
    f:write(raw_data)
    f:close()

    local repo = SceneRepository.new()
    local ok, count = repo:load(tmp_path)
    assert_true(ok, "Repository load should succeed")
    assert_eq(count, 2, "Loaded 2 scenes")

    -- Should be chronologically sorted
    assert_eq(repo.scenes[1].title, "Earlier Scene", "Earlier scene is first")
    assert_eq(repo.scenes[1].id, 1, "Earlier scene ID reindexed to 1")
    assert_eq(repo.scenes[2].title, "Later Scene", "Later scene is second")
    assert_eq(repo.scenes[2].id, 2, "Later scene ID reindexed to 2")

    -- Add a third scene in between
    local add_ok, sc3 = repo:add(TimeCode.from_seconds(150), TimeCode.from_seconds(200), "Middle Scene")
    assert_true(add_ok, "Add scene should succeed")
    assert_eq(repo:count(), 3, "Total count 3")
    assert_eq(repo.scenes[2].title, "Middle Scene", "Middle scene sorted at index 2")
    assert_eq(repo.scenes[2].id, 2, "Middle scene reindexed to 2")
    assert_eq(repo.scenes[3].id, 3, "Later scene reindexed to 3")

    -- Save and re-read
    local save_ok = repo:save()
    assert_true(save_ok, "Save should succeed")

    local repo2 = SceneRepository.new()
    repo2:load(tmp_path)
    -- Delete middle scene and verify reindex
    local del_ok, del_sc = repo2:delete(2)
    assert_true(del_ok, "Delete should succeed")
    assert_eq(del_sc.title, "Middle Scene", "Deleted correct scene")
    assert_eq(repo2:count(), 2, "Remaining count is 2")
    assert_eq(repo2.scenes[1].id, 1, "First scene ID is 1")
    assert_eq(repo2.scenes[2].id, 2, "Last scene re-indexed to 2")
    assert_eq(repo2.scenes[2].title, "Later Scene", "Last scene is Later Scene")

    os.remove(tmp_path)
end)

test("Extension descriptor and menu() hooks", function()
    local desc = descriptor()
    assert_eq(desc.title, "Scene Marker", "Descriptor title matches")
    assert_eq(desc.capabilities[1], "menu", "Menu capability declared")

    local m = menu()
    assert_true(type(m) == "table", "Menu returns table")
    assert_eq(#m, 9, "Menu has exactly 9 clean functional actions")
    assert_true(m[1]:find("Mark Start", 1, true) ~= nil, "First menu item is Mark Start")

    for i, item in ipairs(m) do
        assert_true(item ~= "---", string.format("Menu item %d should not be a separator", i))
        assert_true(item:find("Show / Open", 1, true) == nil, string.format("Menu item %d should not be redundant window opener", i))
    end
end)

-- 4. Platform abstraction tests
test("Platform.quote (POSIX vs Windows)", function()
    local posix_q = Platform.quote("/path/with space/'quote'", false)
    assert_eq(posix_q, "'/path/with space/'\\''quote'\\'''", "POSIX quotes with single quotes")

    local win_q = Platform.quote('C:\\Path With Space\\"quote"', true)
    assert_eq(win_q, '"C:\\Path With Space\\""quote"""', "Windows quotes with double quotes")
end)

test("Platform.bg_command (POSIX vs Windows)", function()
    local posix_bg = Platform.bg_command("ffmpeg -i test.mp4", "/tmp/test.log", false)
    assert_true(posix_bg:match("&%s*$") ~= nil, "POSIX bg command ends with &")
    assert_true(posix_bg:find("/tmp/test.log") ~= nil, "POSIX bg redirects to log")

    local win_bg = Platform.bg_command("ffmpeg -i test.mp4", "C:\\temp\\test.log", true)
    assert_true(win_bg:find('start "" /B') ~= nil, "Windows bg command uses start /B")
end)

test("Platform.script_ext", function()
    assert_eq(Platform.script_ext(false), ".sh", "POSIX script extension is .sh")
    assert_eq(Platform.script_ext(true), ".bat", "Windows script extension is .bat")
end)

-- 5. CutterService tests
test("CutterService.sanitize_filename", function()
    local clean = CutterService.sanitize_filename('Scene 1: "The Heist" / part *2*')
    assert_eq(clean, "Scene_1___The_Heist____part__2", "Special characters replaced with underscores")
end)

test("CutterService.build_cut_command", function()
    local sc = Scene.new(1, TimeCode.from_seconds(10.5), TimeCode.from_seconds(20.75), "Standoff")
    local cmd_posix = CutterService.build_cut_command("/videos/movie.mp4", sc, "/videos/clip1.mp4", false)
    assert_true(cmd_posix:find("-ss 00:00:10.500", 1, true) ~= nil, "Uses dot format for start time")
    assert_true(cmd_posix:find("-to 00:00:20.750", 1, true) ~= nil, "Uses dot format for end time")
    assert_true(cmd_posix:find("-c copy", 1, true) ~= nil, "Uses lossless stream copy")
    assert_true(cmd_posix:find("'/videos/movie.mp4'", 1, true) ~= nil, "Input path properly quoted")
end)

test("CutterService.generate_script (.sh and .bat)", function()
    local scenes = {
        Scene.new(1, TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Intro"),
        Scene.new(2, TimeCode.from_seconds(30), TimeCode.from_seconds(50), "Climax")
    }

    local sh_script = CutterService.generate_script("/media/movie.mkv", scenes, false)
    assert_true(sh_script:find("#!/usr/bin/env bash", 1, true) ~= nil, "Bash shebang present")
    assert_true(sh_script:find("movie_scene_01_Intro.mkv", 1, true) ~= nil, "Output filename formatted")
    assert_true(sh_script:find("movie_scene_02_Climax.mkv", 1, true) ~= nil, "Second scene included")

    local bat_script = CutterService.generate_script("C:\\media\\movie.mkv", scenes, true)
    assert_true(bat_script:find("@echo off", 1, true) ~= nil, "Windows @echo off present")
    assert_true(bat_script:find("pause", 1, true) ~= nil, "Windows script ends with pause")
end)

test("CutterService.export_script writes executable script to disk", function()
    local tmp_video = "/tmp/test_video_" .. tostring(os.time()) .. ".mp4"
    local scenes = { Scene.new(1, TimeCode.from_seconds(5), TimeCode.from_seconds(15), "Demo") }

    local ok, path = CutterService.export_script(tmp_video, scenes, false)
    assert_true(ok, "Export script succeeded")
    assert_true(path:match("_cut_scenes%.sh$") ~= nil, "Output filename has .sh extension")

    local f = io.open(path, "r")
    assert_true(f ~= nil, "Script file exists on disk")
    local content = f:read("*a")
    f:close()
    os.remove(path)
end)

test("CutterService.find_ffmpeg and check_ffmpeg discovery", function()
    -- Check Linux resolution finds snap common bin or system bin
    local linux_bin = CutterService.find_ffmpeg(false)
    assert_true(type(linux_bin) == "string" and #linux_bin > 0, "Finds Linux ffmpeg candidate")

    local ok_linux, res_linux = CutterService.check_ffmpeg(false)
    assert_true(ok_linux, "Linux FFmpeg check succeeds with installed static build: " .. tostring(res_linux))

    -- Check Windows resolution returns candidate or fallback
    local win_bin = CutterService.find_ffmpeg(true)
    assert_true(type(win_bin) == "string" and win_bin:find("ffmpeg%.exe") ~= nil, "Finds Windows ffmpeg candidate")
end)

-- 6. VlcPlayerAdapter tests
test("VlcPlayerAdapter: get_current_time, guess_scn_path, and guess_work_dir", function()
    local tc, err = VlcPlayerAdapter.get_current_time()
    assert_true(tc ~= nil, "Current time returned: " .. tostring(err))
    assert_eq(tc:to_string(true, ","), "00:01:15,450", "Microseconds accurately converted")

    local scn_path = VlcPlayerAdapter.guess_scn_path()
    assert_eq(scn_path, "/home/user/Videos/sample_movie.scn", "Guessed .scn path correctly")

    local work_dir = VlcPlayerAdapter.guess_work_dir()
    assert_eq(work_dir, "/home/user/Videos/", "Guessed work directory correctly")
end)

-- 7. Work Dir & UI Truncation tests
test("CutterService.derive_output_path with custom work_dir", function()
    local sc = Scene.new(1, TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Opening")
    -- Without custom work_dir (inherits video dir)
    local def_path = CutterService.derive_output_path("/media/films/movie.mp4", sc)
    assert_eq(def_path, "/media/films/movie_scene_01_Opening.mp4", "Default uses video directory")

    -- With custom work_dir with trailing slash
    local custom_path1 = CutterService.derive_output_path("/media/films/movie.mp4", sc, "/cuts/scenes/")
    assert_eq(custom_path1, "/cuts/scenes/movie_scene_01_Opening.mp4", "Custom work_dir with trailing slash")

    -- With custom work_dir without trailing slash
    local custom_path2 = CutterService.derive_output_path("/media/films/movie.mp4", sc, "/cuts/scenes")
    assert_eq(custom_path2, "/cuts/scenes/movie_scene_01_Opening.mp4", "Custom work_dir appended with separator")
end)

test("wrap_status_text path-aware line wrapping and optional line cap", function()
    local wrap = T.wrap_status_text
    assert_eq(wrap(""), "", "Empty string returns empty")
    assert_eq(wrap("Ready."), "Ready.", "Short text remains untouched")

    -- Long path wrapped at directory separator
    local long_path = "/home/konstantin/Documents/PythonProjects/scene-maker/very/long/nested/path/to/movie.scn"
    local wrapped = wrap(long_path, 40)
    assert_true(wrapped:find("<br>") ~= nil, "Path wrapped with <br>")
    for line in wrapped:gmatch("[^<]+") do
        local clean = line:gsub("^br>", "")
        assert_true(#clean <= 45, "Wrapped segment within length limit: " .. clean)
    end

    -- By default (no max_lines), all lines are preserved for scrolling
    local six_lines = "1\n2\n3\n4\n5\n6"
    local full_wrapped = wrap(six_lines, 55)
    local full_count = 1
    for _ in full_wrapped:gmatch("<br>") do full_count = full_count + 1 end
    assert_eq(full_count, 6, "All lines preserved for scrollable view")

    -- When max_lines is explicitly passed, text is clamped with ellipsis
    local capped = wrap(six_lines, 55, 4)
    local capped_count = 1
    for _ in capped:gmatch("<br>") do capped_count = capped_count + 1 end
    assert_eq(capped_count, 4, "Clamped to 4 lines when max_lines=4")
    assert_true(capped:find("...", 1, true) ~= nil, "Includes ellipsis when clamped")
end)

test("app:set_status scrollable & copyable status_box rich HTML formatting", function()
    local app = T.app
    local last_box_text = nil
    app.status_box = {
        set_text = function(self, text)
            last_box_text = text
        end
    }

    -- Long single-line error message with full path preserves full details without artificial <br> line breaks
    local long_err = "❌ Failed to save file: /home/konstantin/Documents/PythonProjects/scene-maker/very/long/nested/path/to/movie.scn (Permission denied)"
    app:set_status(long_err, "error")
    assert_true(last_box_text:find("Permission denied", 1, true) ~= nil, "Full error details preserved")
    assert_true(last_box_text:find("color:#c62828", 1, true) ~= nil, "Error rendered with red color style")
    assert_true(last_box_text:find("word-wrap:break-word", 1, true) ~= nil, "Uses fluid CSS word-wrap:break-word")
    assert_true(last_box_text:find("<br>", 1, true) == nil, "Single line message has no artificial <br> breaks")

    -- Multi-line error preserves all lines for vertical scrollbar
    local multi_err = "❌ FFmpeg cut error:\nLine 2 details\nLine 3 details\nLine 4 details\nLine 5 overflow\nLine 6 overflow"
    app:set_status(multi_err, "error")
    local count = 1
    for _ in last_box_text:gmatch("<br>") do count = count + 1 end
    assert_eq(count, 6, "All 6 lines preserved for scrollable QTextBrowser")

    -- Success message formatting with Cyrillic preserves full line without artificial line breaks
    local succ_msg = "✅ Loaded 2 scene(s) from Мераб Мамардашвили - Что такое любовь.scn"
    app:set_status(succ_msg, "success")
    assert_true(last_box_text:find("Мераб Мамардашвили - Что такое любовь.scn", 1, true) ~= nil, "Cyrillic title preserved")
    assert_true(last_box_text:find("<br>", 1, true) == nil, "No premature <br> in Cyrillic title")
    assert_true(last_box_text:find("color:#2e7d32", 1, true) ~= nil, "Success rendered with green color style")
end)

test("CutterService.cut_scene synchronous execution and error log capture", function()
    local sc = Scene.new(1, TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Test")
    -- When video file does not exist, FFmpeg fails and returns error with log details
    local ok, res = CutterService.cut_scene("/tmp/non_existent_input_12345.mp4", sc, false)
    assert_true(not ok, "Cut fails gracefully when input does not exist")
    assert_true(res:find("FFmpeg failed", 1, true) ~= nil, "Error message reports failure")
    assert_true(res:find("Log:", 1, true) ~= nil, "Log file location is reported")
end)

test("app:get_scn_path resolves relative filenames with work_dir", function()
    local app = T.app
    app.workdir_input = {
        get_text = function() return "/workspace/output" end
    }
    app.path_input = {
        get_text = function() return "film_notes.scn" end
    }

    local resolved = app:get_scn_path()
    assert_eq(resolved, "/workspace/output/film_notes.scn", "Relative filename combined with work_dir")

    -- Absolute path should remain untouched
    app.path_input.get_text = function() return "/custom/abs/path.scn" end
    assert_eq(app:get_scn_path(), "/custom/abs/path.scn", "Absolute path unchanged")
end)

test("SceneRepository:update validates and modifies existing scene", function()
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Original 1")
    repo:add(TimeCode.from_seconds(30), TimeCode.from_seconds(40), "Original 2")

    -- Valid update
    local ok, updated = repo:update(1, TimeCode.from_seconds(15), TimeCode.from_seconds(25), "Updated Title")
    assert_true(ok, "Valid update succeeds")
    assert_eq(updated.title, "Updated Title", "Title updated")
    assert_eq(updated.start_tc.total_sec, 15, "Start timecode updated")
    assert_eq(updated.end_tc.total_sec, 25, "End timecode updated")

    -- Invalid update: end <= start rejected
    local bad_ok, bad_err = repo:update(1, TimeCode.from_seconds(30), TimeCode.from_seconds(20), "Bad")
    assert_true(not bad_ok, "End <= start rejected")
    assert_true(bad_err:find("greater than", 1, true) ~= nil, "Appropriate error message")

    -- Non-existent ID rejected
    local missing_ok, missing_err = repo:update(999, TimeCode.from_seconds(1), TimeCode.from_seconds(2), "Missing")
    assert_true(not missing_ok, "Missing ID rejected")
end)

test("app:on_edit_selected and app:on_save_scene dual-mode workflow", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "First Scene")
    app.repo = repo

    local start_val, end_val, title_val = "", "", ""
    app.start_input = {
        get_text = function() return start_val end,
        set_text = function(self, t) start_val = t end
    }
    app.end_input = {
        get_text = function() return end_val end,
        set_text = function(self, t) end_val = t end
    }
    app.title_input = {
        get_text = function() return title_val end,
        set_text = function(self, t) title_val = t end
    }
    app.list = {
        get_selection = function() return { [1] = "Row 1" } end,
        clear = function() end,
        add_value = function() end
    }
    app.status_box = {
        set_text = function() end
    }
    local tmp_scn = os.tmpname() .. ".scn"
    app.path_input = {
        get_text = function() return tmp_scn end
    }

    -- 1. Click edit: inputs populated with scene 1
    app:on_edit_selected()
    assert_eq(app.editing_scene_id, 1, "Edit mode active for scene 1")
    assert_eq(start_val, "00:00:10,000", "Start input populated")
    assert_eq(end_val, "00:00:20,000", "End input populated")
    assert_eq(title_val, "First Scene", "Title input populated")

    -- 2. Modify title and save
    title_val = "Modified Scene 1"
    app:on_save_scene()
    assert_eq(app.editing_scene_id, nil, "Edit mode reset after save")
    assert_eq(title_val, "", "Title input cleared after save")
    assert_eq(repo:get_by_id(1).title, "Modified Scene 1", "Scene updated in repository")

    -- 3. In normal mode (not editing), save creates a new scene
    start_val = "00:00:30,000"
    end_val = "00:00:40,000"
    title_val = "Second Scene"
    app:on_save_scene()
    assert_eq(repo:count(), 2, "Second scene added via on_save_scene")
    assert_eq(repo:get_by_id(2).title, "Second Scene", "Second scene title saved")

    -- 4. Test toggling edit mode off
    app:on_edit_selected()
    assert_eq(app.editing_scene_id, 1, "Edit mode re-entered")
    app:on_edit_selected()
    assert_eq(app.editing_scene_id, nil, "Edit mode toggled off")
    assert_eq(title_val, "", "Inputs cleared when edit mode cancelled")

    os.remove(tmp_scn)
end)

print("--------------------------------------------------")
print(string.format("Test Results: %d/%d passed (%s)", passed_tests, total_tests, passed_tests == total_tests and "ALL PASSED" or "SOME FAILED"))
print("--------------------------------------------------")

if passed_tests ~= total_tests then
    os.exit(1)
end
