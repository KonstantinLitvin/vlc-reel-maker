-- Unit test suite for ReelMaker
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
                uri = function() return "file:///home/user/Videos/sample_movie.mp4" end,
                duration = function() return 300.0 end
            }
        end
    },
    strings = {
        decode_uri = function(u) return u end
    },
    dialog = function(title)
        local dd_items = {}
        local dd_val = 0
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
                    set_text = function(self, t) val = t end
                }
            end,
            add_dropdown = function(col, row, col_span, row_span)
                return {
                    clear = function(self) dd_items = {}; dd_val = 0 end,
                    add_value = function(self, str, id)
                        dd_items[id] = str
                        if dd_val == 0 then dd_val = id end
                    end,
                    get_value = function(self) return dd_val end,
                    set_value = function(self, id) dd_val = id end
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

-- Build a hermetic English test bundle so test assertions remain reproducible
-- regardless of local distribution build locale.
local test_bundle = "dist/reel-maker-test.lua"
local build_cmd = "luajit scripts/build.lua en " .. test_bundle .. " 2>/dev/null || luajit ../scripts/build.lua en " .. test_bundle .. " 2>/dev/null"
os.execute(build_cmd)
local chunk, load_err = loadfile(test_bundle) or loadfile("../" .. test_bundle)
if not chunk then
    -- Fallback to default dist
    local script_path = "dist/reel-maker.lua"
    chunk, load_err = loadfile(script_path) or loadfile("../" .. script_path)
end
assert(chunk, "Failed to load test bundle: " .. tostring(load_err))
chunk()

local T = _G.__TEST_CLASSES__
assert(T, "Test classes hook not exported from ReelMaker bundle")

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
print("Running ReelMaker Test Suite (Unit & System)")
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

test("TimeCode.from_string length cap and range bounds", function()
    -- Valid 12-char
    local tc, err = TimeCode.from_string("00:01:23,456")
    assert_true(tc ~= nil, "Valid 12-char timecode accepted")

    -- Exceeding 12 chars rejected
    local tc_long, err_long = TimeCode.from_string("00:01:23,4567")
    assert_true(tc_long == nil, "Over 12 chars rejected")
    assert_true(err_long:find("exceeds maximum length of 12 characters", 1, true) ~= nil, "Length error reported")

    -- Minutes >= 60 rejected
    local tc_min, err_min = TimeCode.from_string("00:60:00")
    assert_true(tc_min == nil, "Minutes >= 60 rejected")
    assert_true(err_min:find("Minutes must be between 0 and 59", 1, true) ~= nil, "Minutes error reported")

    -- Seconds >= 60 rejected
    local tc_sec, err_sec = TimeCode.from_string("00:00:60")
    assert_true(tc_sec == nil, "Seconds >= 60 rejected")
    assert_true(err_sec:find("Seconds must be between 0 and 59", 1, true) ~= nil, "Seconds error reported")
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

test("Scene.new and SceneRepository boundary validation with max_duration", function()
    local s_tc = TimeCode.from_seconds(10)
    local e_tc = TimeCode.from_seconds(60)
    local max_tc = TimeCode.from_seconds(60)

    -- Valid: end == duration (exact last millisecond)
    local sc, err = Scene.new(1, s_tc, e_tc, "Valid Edge", max_tc)
    assert_true(sc ~= nil, "Should allow end == max_duration")
    assert_true(err == nil, "No error on valid boundary")

    -- Invalid: end > duration
    local e_over = TimeCode.from_seconds(60.1)
    local sc_bad, err_bad = Scene.new(1, s_tc, e_over, "Over End", max_tc)
    assert_true(sc_bad == nil, "Should reject end > max_duration")
    assert_true(err_bad:find("exceeds media duration", 1, true) ~= nil, "Error mentions exceeds media duration")

    -- Invalid: start >= duration
    local s_over = TimeCode.from_seconds(60)
    local e_way_over = TimeCode.from_seconds(70)
    local sc_bad2, err_bad2 = Scene.new(1, s_over, e_way_over, "Over Start", max_tc)
    assert_true(sc_bad2 == nil, "Should reject start >= max_duration")
    assert_true(err_bad2:find("cannot be greater than or equal", 1, true) ~= nil, "Error mentions start at or beyond duration")

    -- Repository add with max_duration
    local repo = SceneRepository.new()
    local ok_add, res_add = repo:add(s_tc, e_over, "Over End", max_tc)
    assert_true(not ok_add, "repo:add rejects end > max_duration")
    assert_true(res_add:find("exceeds media duration", 1, true) ~= nil, "repo:add returns error message")

    -- Repository update with max_duration
    local ok_ok, sc_ok = repo:add(s_tc, e_tc, "Valid", max_tc)
    assert_true(ok_ok, "repo:add succeeds for valid edge")
    local ok_up, res_up = repo:update(1, s_tc, e_over, "Over End", max_tc)
    assert_true(not ok_up, "repo:update rejects end > max_duration")
    assert_true(res_up:find("exceeds media duration", 1, true) ~= nil, "repo:update returns error message")
end)

test("Scene:to_scn_block formatting", function()
    local sc = Scene.new(2, TimeCode.from_seconds(60), TimeCode.from_seconds(120.5), "Dialogue")
    local block = sc:to_scn_block()
    local expected = "2\n00:01:00,000 --> 00:02:00,500\nDialogue"
    assert_eq(block, expected, "SCN block matches specification")
end)

test("Scene.TABLE_HEADER and Scene:to_table_row formatting", function()
    assert_true(Scene.TABLE_HEADER ~= nil, "TABLE_HEADER constant exists")
    assert_eq(Scene.TABLE_HEADER, "№    Start                   End                     Title", "TABLE_HEADER content matches")
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
    assert_eq(desc.title, "ReelMaker v1.2", "Descriptor title matches")
    assert_eq(desc.shortdesc, "ReelMaker v1.2", "Descriptor shortdesc matches title for VLC View menu")
    assert_eq(desc.version, "1.2", "Descriptor version matches")
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

test("CutterService.export_script writes executable script to disk and includes .scn name", function()
    local tmp_video = "/tmp/test_video_" .. tostring(os.time()) .. ".mp4"
    local scenes = { Scene.new(1, TimeCode.from_seconds(5), TimeCode.from_seconds(15), "Demo") }

    -- 1. Default without scn_path
    local ok, path = CutterService.export_script(tmp_video, scenes, false)
    assert_true(ok, "Export script succeeded")
    assert_true(path:match("_cut_scenes%.sh$") ~= nil, "Output filename has .sh extension")
    os.remove(path)

    -- 2. With distinct scn_path
    local ok2, path2 = CutterService.export_script(tmp_video, scenes, false, "/tmp", "/tmp/highlights.scn")
    assert_true(ok2, "Export script with scn_path succeeded")
    assert_true(path2:find("highlights_cut_scenes%.sh") ~= nil, "Output script contains scn name: " .. path2)
    os.remove(path2)

    -- 3. With scn_path that shares prefix
    local ok3, path3 = CutterService.export_script(tmp_video, scenes, false, "/tmp", "/tmp/test_video_part1.scn")
    assert_true(ok3, "Export script with prefixed scn_path succeeded")
    assert_true(path3:find("part1_cut_scenes%.sh") ~= nil, "Output script preserves stem prefix: " .. path3)
    os.remove(path3)
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

    local dur, d_err = VlcPlayerAdapter.get_media_duration()
    assert_true(dur ~= nil, "Media duration returned: " .. tostring(d_err))
    assert_eq(dur:to_string(true, ","), "00:05:00,000", "Media duration matches mock (300s)")
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

test("truncate_middle prevents UI expansion on long media filenames", function()
    local trunc = T.truncate_middle
    assert_true(trunc ~= nil, "truncate_middle hook exported")
    assert_eq(trunc(""), "", "Empty string handled")
    assert_eq(trunc("short.mp4", 45), "short.mp4", "Short filename untouched")

    -- Long ASCII filename
    local long_ascii = "A_Very_Long_Movie_Name_2026_1080p_BluRay_x264_DTS_HD_MA_5_1_Dual_Audio_English_Russian_Director_Cut.mkv"
    local res_ascii = trunc(long_ascii, 45)
    assert_eq(#res_ascii, 45, "Long ASCII truncated to exactly 45 characters")
    assert_true(res_ascii:find("...", 1, true) ~= nil, "Contains ellipsis")
    assert_true(res_ascii:sub(-4) == ".mkv", "Preserves extension")
    assert_true(res_ascii:sub(1, 10) == "A_Very_Lon", "Preserves title prefix")

    -- Multi-byte UTF-8 Russian filename
    local long_ru = "Внутренняя_империя_[torrents.ru]_by_Scarabey_очень_длинное_название_фильма.avi"
    local res_ru = trunc(long_ru, 45)
    assert_true(res_ru:find("...", 1, true) ~= nil, "Contains ellipsis in Russian filename")
    assert_true(res_ru:sub(-4) == ".avi", "Preserves .avi extension in Russian filename")

    -- Verify UTF-8 character count (not byte length) equals 45
    local char_count = 0
    for _ in res_ru:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        char_count = char_count + 1
    end
    assert_eq(char_count, 45, "Russian filename truncated to exactly 45 UTF-8 characters")
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

    -- Multi-line error is clamped to 4 visible lines to prevent distorting rich text label
    local multi_err = "❌ FFmpeg cut error:\nLine 2 details\nLine 3 details\nLine 4 details\nLine 5 overflow\nLine 6 overflow"
    app:set_status(multi_err, "error")
    local count = 1
    for _ in last_box_text:gmatch("<br>") do count = count + 1 end
    assert_eq(count, 4, "Clamped to 4 lines max to prevent dialog distortion")
    assert_true(last_box_text:find("log file", 1, true) ~= nil, "Refers to log file on clamp")

    -- HTML entities escaping
    local unescaped_msg = "⚠️ Testing <encoder> & \"special\" characters"
    app:set_status(unescaped_msg, "warn")
    assert_true(last_box_text:find("&lt;encoder&gt;", 1, true) ~= nil, "HTML < and > escaped")
    assert_true(last_box_text:find("&amp;", 1, true) ~= nil, "HTML & escaped")
    assert_true(last_box_text:find("&quot;", 1, true) ~= nil, "HTML quotes escaped")

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

test("app:on_save_scene validates timestamps against active media duration", function()
    local app = T.app
    local repo = SceneRepository.new()
    app.repo = repo
    local last_status = ""
    app.status_box = {
        set_text = function(self, t) last_status = t end
    }
    local tmp_scn = os.tmpname() .. ".scn"
    app.path_input = {
        get_text = function() return tmp_scn end
    }

    local s_val = "00:01:00,000"
    local e_val = "00:06:00,000" -- exceeds 300s (00:05:00,000)
    local t_val = "Too Long Scene"

    app.start_input = { get_text = function() return s_val end, set_text = function(self, v) s_val = v end }
    app.end_input   = { get_text = function() return e_val end, set_text = function(self, v) e_val = v end }
    app.title_input = { get_text = function() return t_val end, set_text = function(self, v) t_val = v end }

    app:on_save_scene()
    assert_eq(repo:count(), 0, "Scene exceeding duration not saved")
    assert_true(last_status:find("exceeds media duration", 1, true) ~= nil, "Status reports end exceeds media duration")

    -- Start exceeds duration
    s_val = "00:05:30,000"
    e_val = "00:06:00,000"
    app:on_save_scene()
    assert_eq(repo:count(), 0, "Scene with start past duration not saved")
    assert_true(last_status:find("cannot be at or beyond media duration", 1, true) ~= nil, "Status reports start exceeds media duration")

    -- Valid boundary: end == 00:05:00,000
    s_val = "00:04:00,000"
    e_val = "00:05:00,000"
    app:on_save_scene()
    assert_eq(repo:count(), 1, "Valid boundary scene saved successfully")
    assert_true(last_status:find("Added", 1, true) ~= nil or last_status:find("✅", 1, true) ~= nil, "Scene added status")
    pcall(os.remove, tmp_scn)
end)

test("SceneRepository:delete_many deletes multiple scenes atomically and reindexes", function()
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    repo:add(TimeCode.from_seconds(30), TimeCode.from_seconds(40), "Scene 2")
    repo:add(TimeCode.from_seconds(50), TimeCode.from_seconds(60), "Scene 3")
    repo:add(TimeCode.from_seconds(70), TimeCode.from_seconds(80), "Scene 4")

    -- Delete scenes 2 and 3 atomically
    local ok, count = repo:delete_many({2, 3})
    assert_true(ok, "delete_many succeeds")
    assert_eq(count, 2, "Deleted 2 scenes")
    assert_eq(repo:count(), 2, "2 scenes remain")
    assert_eq(repo:get_by_id(1).title, "Scene 1", "Scene 1 remains as ID 1")
    assert_eq(repo:get_by_id(2).title, "Scene 4", "Scene 4 reindexed to ID 2")

    -- Attempt to delete non-existent IDs
    local bad_ok, bad_err = repo:delete_many({99, 100})
    assert_true(not bad_ok, "delete_many fails for non-existent IDs")
end)

test("Multi-selection handling: get_selected_scenes, batch cut and batch delete", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    repo:add(TimeCode.from_seconds(30), TimeCode.from_seconds(40), "Scene 2")
    repo:add(TimeCode.from_seconds(50), TimeCode.from_seconds(60), "Scene 3")
    app.repo = repo

    -- Mock list selection
    local cur_selection = {}
    app.list = {
        get_selection = function() return cur_selection end,
        clear = function() end,
        add_value = function() end
    }

    local last_status = nil
    app.set_status = function(self, msg) last_status = msg end

    -- 1. No selection
    cur_selection = {}
    assert_eq(#app:get_selected_scenes(), 0, "No scenes returned")
    local single, err = app:get_selected_scene()
    assert_true(single == nil and err:find("No scene selected", 1, true) ~= nil, "Single select returns no scene error")

    -- 2. Header row selected (ID 0)
    cur_selection = { [0] = "ID Start End Title" }
    assert_eq(#app:get_selected_scenes(), 0, "Header row excluded")
    single, err = app:get_selected_scene()
    assert_true(single == nil and err:find("Header row selected", 1, true) ~= nil, "Header row error reported")

    -- 3. Multi-selection: IDs 1 and 3 selected (plus header 0)
    cur_selection = { [0] = "Header", [1] = "Scene 1", [3] = "Scene 3" }
    local scenes = app:get_selected_scenes()
    assert_eq(#scenes, 2, "2 scenes returned")
    assert_eq(scenes[1].id, 1, "First is Scene 1")
    assert_eq(scenes[2].id, 3, "Second is Scene 3")

    -- get_selected_scene guards against multiple selection for edit/jump
    single, err = app:get_selected_scene()
    assert_true(single == nil and err:find("Multiple scenes selected", 1, true) ~= nil, "Multiple scenes guarded against single-select")

    -- 4. Batch delete requires 2-step confirmation for >1 scenes
    app:on_delete_selected()
    assert_true(last_status:find("Click 🗑️ Delete again to confirm", 1, true) ~= nil, "First click asks for confirmation")
    assert_eq(repo:count(), 3, "Scenes not yet deleted before confirmation")

    -- Second click executes deletion
    app:on_delete_selected()
    assert_true(last_status:find("Deleted 2 scenes", 1, true) ~= nil, "Batch delete status reported after confirmation")
    assert_eq(repo:count(), 1, "Only 1 scene remaining")
    assert_eq(repo:get_by_id(1).title, "Scene 2", "Old Scene 2 reindexed to ID 1")
end)

test("Edit mode reference tracking and invalidation on delete or file reload", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    repo:add(TimeCode.from_seconds(30), TimeCode.from_seconds(40), "Scene 2")
    app.repo = repo

    local cur_sel = { [2] = "Scene 2" }
    app.list = {
        get_selection = function() return cur_sel end,
        clear = function() end,
        add_value = function() end
    }

    local s_text, e_text, t_text = "", "", ""
    app.start_input = { get_text = function() return s_text end, set_text = function(self, t) s_text = t end }
    app.end_input   = { get_text = function() return e_text end, set_text = function(self, t) e_text = t end }
    app.title_input = { get_text = function() return t_text end, set_text = function(self, t) t_text = t end }
    app.status_box  = { set_text = function() end }

    -- Enter edit mode for Scene 2
    app:on_edit_selected()
    assert_eq(app.editing_scene.title, "Scene 2", "Editing Scene 2 reference tracked")

    -- Deleting scene 1 reindexes Scene 2 to ID 1, but edit mode is cancelled cleanly
    cur_sel = { [1] = "Scene 1" }
    app:on_delete_selected()
    assert_eq(app.editing_scene, nil, "Edit mode cancelled on deletion")
    assert_eq(app.editing_scene_id, nil, "editing_scene_id cancelled on deletion")
    assert_eq(t_text, "", "Inputs cleared on edit cancellation")
end)

test("Video context mismatch guard in app:on_cut_selected", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    app.repo = repo

    app.list = {
        get_selection = function() return { [1] = "Scene 1" } end,
        clear = function() end,
        add_value = function() end
    }

    local last_status = nil
    app.set_status = function(self, msg) last_status = msg end

    -- Loaded scenes belong to video_A.mp4
    app.loaded_video_path = "/media/video_A.mp4"

    -- Mock VlcPlayerAdapter to return video_B.mp4 (playlist advanced)
    local old_get_video = T.VlcPlayerAdapter.get_video_path
    T.VlcPlayerAdapter.get_video_path = function() return "/media/video_B.mp4" end

    app:on_cut_selected()
    assert_true(last_status:find("Video mismatch", 1, true) ~= nil, "Cut blocked due to video mismatch")

    -- Restore mock
    T.VlcPlayerAdapter.get_video_path = old_get_video
end)

test("Platform.is_absolute and Platform.resolve_scn path resolution", function()
    -- Platform.is_absolute
    assert_true(Platform.is_absolute("/home/user/video.mp4", false), "POSIX absolute path detected")
    assert_true(Platform.is_absolute("~/videos/video.mp4", false), "POSIX home path detected")
    assert_true(not Platform.is_absolute("video.mp4", false), "Relative filename is not absolute")
    assert_true(not Platform.is_absolute("sub/video.mp4", false), "Relative subpath is not absolute")

    assert_true(Platform.is_absolute("C:\\video.mp4", true), "Windows absolute drive path detected")
    assert_true(Platform.is_absolute("\\\\server\\share\\video.mp4", true), "Windows UNC path detected")
    assert_true(not Platform.is_absolute("video.mp4", true), "Windows relative path is not absolute")

    -- Platform.resolve_scn
    -- 1. Bare relative filename with work_dir
    local r1 = Platform.resolve_scn("test.scn", "/work/dir", nil, false)
    assert_eq(r1, "/work/dir/test.scn", "Relative filename joined with work_dir")

    -- 2. Auto-append .scn extension if omitted
    local r2 = Platform.resolve_scn("test", "/work/dir", nil, false)
    assert_eq(r2, "/work/dir/test.scn", "Extension auto-appended")

    -- 3. Relative subpath with work_dir
    local r3 = Platform.resolve_scn("cuts/test.scn", "/work/dir", nil, false)
    assert_eq(r3, "/work/dir/cuts/test.scn", "Relative subpath joined with work_dir")

    -- 4. Fallback to video directory when work_dir is empty or nil
    local r4 = Platform.resolve_scn("test.scn", "", "/media/video/", false)
    assert_eq(r4, "/media/video/test.scn", "Fallback to video directory when work_dir is empty")

    local r5 = Platform.resolve_scn("test.scn", nil, "/media/video", false)
    assert_eq(r5, "/media/video/test.scn", "Fallback to video directory with missing trailing slash")

    -- 5. Absolute path preserved
    local r6 = Platform.resolve_scn("/custom/abs.scn", "/work/dir", "/fallback", false)
    assert_eq(r6, "/custom/abs.scn", "Absolute POSIX path preserved")

    local r7 = Platform.resolve_scn("D:\\custom\\abs.scn", "C:\\work", "C:\\fallback", true)
    assert_eq(r7, "D:\\custom\\abs.scn", "Absolute Windows path preserved")
end)

test("Platform.relative_display strips work_dir for cleaner display", function()
    -- Inside work_dir with trailing slash
    local d1 = Platform.relative_display("/home/user/Videos/movie.scn", "/home/user/Videos/")
    assert_eq(d1, "movie.scn", "Strips work_dir with trailing slash")

    -- Inside work_dir without trailing slash
    local d2 = Platform.relative_display("/home/user/Videos/movie.scn", "/home/user/Videos")
    assert_eq(d2, "movie.scn", "Strips work_dir without trailing slash")

    -- Windows backslash path
    local d3 = Platform.relative_display("C:\\Videos\\movie.scn", "C:\\Videos\\")
    assert_eq(d3, "movie.scn", "Strips Windows work_dir with backslash")

    local d4 = Platform.relative_display("C:\\Videos\\movie.scn", "C:\\Videos")
    assert_eq(d4, "movie.scn", "Strips Windows work_dir without trailing backslash")

    -- Outside work_dir returns full path
    local d5 = Platform.relative_display("/other/dir/movie.scn", "/home/user/Videos")
    assert_eq(d5, "/other/dir/movie.scn", "Preserves path outside work_dir")

    -- Empty work_dir returns original path
    local d6 = Platform.relative_display("/home/user/Videos/movie.scn", "")
    assert_eq(d6, "/home/user/Videos/movie.scn", "Returns original path when work_dir is empty")
    local d7 = Platform.relative_display("/home/user/Videos/movie.scn", nil)
    assert_eq(d7, "/home/user/Videos/movie.scn", "Returns original path when work_dir is nil")
end)

test("SceneRepository:clear resets repository state", function()
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    repo:add(TimeCode.from_seconds(30), TimeCode.from_seconds(40), "Scene 2")
    assert_eq(repo:count(), 2, "Repo contains 2 scenes")

    repo:clear()
    assert_eq(repo:count(), 0, "Repo count is 0 after clear")
    assert_eq(#repo.scenes, 0, "Scenes table is empty after clear")
    assert_eq(repo.file_path, "", "File path is reset after clear")
end)

test("app:on_new_file lifecycle and 2-step confirmation guard", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    app.repo = repo
    app.pending_new_confirm = nil

    local last_status = ""
    app.set_status = function(self, msg) last_status = msg end
    app.list = {
        clear = function() end,
        add_value = function() end
    }

    -- Step 1: Click New when scenes exist -> asks for confirmation
    app:on_new_file()
    assert_true(app.pending_new_confirm == true, "Confirmation state set on 1st click")
    assert_true(last_status:find("Click 'New' again", 1, true) ~= nil, "Confirmation warning shown")
    assert_eq(repo:count(), 1, "Scenes NOT wiped before confirmation")

    -- Step 2: Click New second time -> clears repository and resets confirmation
    app:on_new_file()
    assert_eq(app.pending_new_confirm, nil, "Confirmation state cleared")
    assert_eq(repo:count(), 0, "Repository cleared after confirmation")
    assert_true(last_status:find("Started new empty scene list", 1, true) ~= nil, "Ready status shown")

    -- Immediate clear when already 0 scenes
    app:on_new_file()
    assert_eq(app.pending_new_confirm, nil, "No confirmation required when repo is empty")
end)

test("app:on_save_as saves current scenes to specified .scn file", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Branch Scene")
    app.repo = repo

    local target_file = "/tmp/test_save_as_" .. os.time() .. ".scn"
    app.path_input = {
        get_text = function() return target_file end
    }
    app.workdir_input = {
        get_text = function() return "" end
    }

    local last_status = ""
    app.set_status = function(self, msg) last_status = msg end

    app:on_save_as()
    assert_true(last_status:find("Saved 1 scene(s)", 1, true) ~= nil, "Save As reports success")
    assert_eq(app.loaded_scn_path, target_file, "loaded_scn_path updated")

    -- Verify file exists and content matches
    local f = io.open(target_file, "r")
    assert_true(f ~= nil, "Saved .scn file exists on disk")
    local content = f:read("*a")
    f:close()
    os.remove(target_file)
    assert_true(content:find("Branch Scene", 1, true) ~= nil, "Content persisted correctly")
end)

test("app:on_load_file distinguishes missing files from errors", function()
    local app = T.app
    app.repo = SceneRepository.new()

    app.path_input = {
        get_text = function() return "/tmp/completely_nonexistent_file_98765.scn" end
    }
    app.workdir_input = {
        get_text = function() return "" end
    }

    local last_status = ""
    app.set_status = function(self, msg) last_status = msg end

    app:on_load_file()
    assert_true(last_status:find("File not found", 1, true) ~= nil, "Missing file reports File not found")
    assert_true(last_status:find("Click 'New'", 1, true) ~= nil, "Advises user to click New")
end)

test("app:on_export_script exports selected scenes symmetrically with Cut", function()
    local app = T.app
    local repo = SceneRepository.new()
    repo:add(TimeCode.from_seconds(10), TimeCode.from_seconds(20), "Scene 1")
    repo:add(TimeCode.from_seconds(30), TimeCode.from_seconds(40), "Scene 2")
    repo:add(TimeCode.from_seconds(50), TimeCode.from_seconds(60), "Scene 3")
    app.repo = repo

    -- Mock video path
    local old_get_video = T.VlcPlayerAdapter.get_video_path
    local test_video = "/tmp/test_video_export.mp4"
    T.VlcPlayerAdapter.get_video_path = function() return test_video end

    -- Select only Scene 2
    app.list = {
        get_selection = function() return { [2] = "Scene 2" } end
    }
    app.workdir_input = {
        get_text = function() return "/tmp" end
    }
    app.loaded_video_path = test_video
    app.loaded_scn_path = "/tmp/test_video_export.scn"

    local last_status = ""
    app.set_status = function(self, msg) last_status = msg end

    app:on_export_script()
    assert_true(last_status:find("Exported cut script for 1 selected scene", 1, true) ~= nil, "Export script reports selected count")

    -- Check generated script content
    local ext = Platform.script_ext()
    local script_file = "/tmp/test_video_export_cut_scenes" .. ext
    local f = io.open(script_file, "r")
    assert_true(f ~= nil, "Generated script exists")
    local script_text = f:read("*a")
    f:close()
    os.remove(script_file)

    assert_true(script_text:find("Scene 2", 1, true) ~= nil, "Script contains selected Scene 2")
    assert_true(script_text:find("Scene 1", 1, true) == nil, "Script does NOT contain unselected Scene 1")
    assert_true(script_text:find("Scene 3", 1, true) == nil, "Script does NOT contain unselected Scene 3")

    -- Verify exporting with distinct scn name incorporates .scn stem into script filename
    app.loaded_scn_path = "/tmp/custom_highlights.scn"
    app:on_export_script()
    local custom_script = "/tmp/test_video_export_custom_highlights_cut_scenes" .. ext
    local f_custom = io.open(custom_script, "r")
    assert_true(f_custom ~= nil, "Script containing custom scn name exists on disk")
    if f_custom then f_custom:close() end
    os.remove(custom_script)

    -- Restore mock and state
    T.VlcPlayerAdapter.get_video_path = old_get_video
    app.list = nil
    app.loaded_scn_path = ""
    app.loaded_video_path = ""
end)

-- 41. Platform directory management & discovery tests
test("Platform.dir_exists and Platform.ensure_dir", function()
    local test_dir = "/tmp/test_reel_maker_dir_" .. os.time()
    os.execute("rm -rf " .. Platform.quote(test_dir, false))

    assert_true(not Platform.dir_exists(test_dir, false), "New dir does not exist yet")

    -- Ensure dir creates directory
    local ok, was_created = Platform.ensure_dir(test_dir, false)
    assert_true(ok, "ensure_dir succeeded")
    assert_true(was_created, "Directory was newly created")
    assert_true(Platform.dir_exists(test_dir, false), "Directory now exists")

    -- Ensure dir on existing directory is idempotent
    local ok2, was_created2 = Platform.ensure_dir(test_dir, false)
    assert_true(ok2, "ensure_dir on existing dir succeeded")
    assert_true(not was_created2, "Directory was NOT recreated (idempotent)")

    -- Clean up
    os.execute("rm -rf " .. Platform.quote(test_dir, false))
end)

test("Platform.list_scn_files finds and sorts .scn files only", function()
    local test_dir = "/tmp/test_scn_scan_" .. os.time()
    os.execute("mkdir -p " .. Platform.quote(test_dir, false))

    -- Create test files
    local f1 = io.open(test_dir .. "/beta_movie.scn", "w"); f1:write("test"); f1:close()
    local f2 = io.open(test_dir .. "/alpha_movie.scn", "w"); f2:write("test"); f2:close()
    local f3 = io.open(test_dir .. "/gamma_movie.SCN", "w"); f3:write("test"); f3:close()
    local f4 = io.open(test_dir .. "/ignored.txt", "w"); f4:write("test"); f4:close()
    local f5 = io.open(test_dir .. "/ignored.mp4", "w"); f5:write("test"); f5:close()

    local scn_files = Platform.list_scn_files(test_dir, false)
    assert_eq(#scn_files, 3, "Found exactly 3 .scn files (including .SCN)")
    assert_eq(scn_files[1], "alpha_movie.scn", "First file sorted alphabetically")
    assert_eq(scn_files[2], "beta_movie.scn", "Second file sorted alphabetically")
    assert_eq(scn_files[3], "gamma_movie.SCN", "Third file sorted alphabetically")

    -- Clean up
    os.execute("rm -rf " .. Platform.quote(test_dir, false))
end)

test("app:update_media_display and app:on_set_scn_file workflow", function()
    local test_dir = "/tmp/test_set_scn_" .. os.time()
    os.execute("mkdir -p " .. Platform.quote(test_dir, false))

    -- 1. Test update_media_display
    local media_text = ""
    T.app.media_box = {
        set_text = function(self, t) media_text = t end
    }
    T.app:update_media_display()
    assert_true(media_text:find("Media:"), "Media banner formatted")

    -- Mock list widget for refresh_list()
    local list_items = {}
    T.app.list = {
        clear = function() list_items = {} end,
        add_value = function(self, val, id) table.insert(list_items, { val = val, id = id }) end,
        get_selection = function() return {} end
    }

    -- 2. Test on_set_scn_file with an existing file
    local existing_scn = test_dir .. "/existing.scn"
    local f = io.open(existing_scn, "w")
    f:write("1\n00:01:00,000 --> 00:02:00,000\nExisting Scene\n")
    f:close()

    local path_val = existing_scn
    T.app.path_input = {
        get_text = function() return path_val end,
        set_text = function(self, t) path_val = t end
    }
    if not T.app.repo then
        T.app.repo = SceneRepository.new()
    end

    T.app:on_set_scn_file()
    assert_eq(T.app.loaded_scn_path, existing_scn, "Loaded scn path set to existing file")
    assert_eq(path_val, "existing.scn", "path_input displays bare filename")
    assert_eq(T.app.repo:count(), 1, "Repo loaded 1 scene from existing file")
    assert_eq(T.app.repo.scenes[1].title, "Existing Scene", "Scene title loaded correctly")
    assert_true(#list_items >= 2, "List widget populated with header and scene row")

    -- 3. Test on_set_scn_file with a new file (plays 'New' role)
    local new_scn = test_dir .. "/new_scenes.scn"
    path_val = new_scn
    -- First call prompts confirmation because repo has 1 scene
    T.app:on_set_scn_file()
    assert_true(T.app.pending_new_confirm == true, "Confirmation prompted when in-memory scenes exist")

    -- Second call confirms and starts new empty file
    T.app:on_set_scn_file()
    assert_eq(T.app.loaded_scn_path, new_scn, "Loaded scn path set to new file")
    assert_eq(path_val, "new_scenes.scn", "path_input displays bare filename for new file")
    assert_eq(T.app.repo:count(), 0, "Repo initialized to 0 scenes for new file (New role)")

    local f_check = io.open(new_scn, "r")
    assert_true(f_check ~= nil, "New .scn file was created on disk")
    if f_check then f_check:close() end

    -- Clean up
    os.execute("rm -rf " .. Platform.quote(test_dir, false))
    T.app.media_box = nil
    T.app.path_input = nil
    T.app.list = nil
end)

test("app:on_set_work_dir creates directory, creates media-stem .scn file, and lists available scn files", function()
    local test_dir = "/tmp/test_set_workdir_" .. os.time()
    os.execute("rm -rf " .. Platform.quote(test_dir, false))

    T.app.workdir_input = {
        get_text = function() return test_dir end
    }

    local path_val = "old_file.scn"
    T.app.path_input = {
        get_text = function() return path_val end,
        set_text = function(self, t) path_val = t end
    }
    T.app.loaded_scn_path = ""

    local last_status = ""
    local old_set_status = T.app.set_status
    T.app.set_status = function(self, msg, lvl) last_status = msg end

    -- Mock list for refresh_list
    T.app.list = {
        clear = function() end,
        add_value = function() end,
        get_selection = function() return {} end
    }

    T.app:on_set_work_dir()
    assert_true(Platform.dir_exists(test_dir, false), "Work dir was created on disk")
    assert_true(last_status:find("Created new directory", 1, true) ~= nil, "Status reports directory creation")
    assert_true(last_status:find("Available .scn files", 1, true) ~= nil, "Status reports available .scn files")
    assert_eq(path_val, "sample_movie.scn", "path_input updated to media-stem filename only")

    local f_check = io.open(test_dir .. "/sample_movie.scn", "r")
    assert_true(f_check ~= nil, "Media-stem .scn file was created on disk in new work dir")
    if f_check then f_check:close() end

    -- Re-running on existing dir reports set work dir and loads existing
    T.app:on_set_work_dir()
    assert_true(last_status:find("Set Work Dir", 1, true) ~= nil, "Status reports work dir set")
    assert_true(last_status:find("Loaded", 1, true) ~= nil, "Loads existing media-stem file")

    -- Clean up
    os.execute("rm -rf " .. Platform.quote(test_dir, false))
    T.app.set_status = old_set_status
    T.app.workdir_input = nil
    T.app.path_input = nil
    T.app.list = nil
    T.app.loaded_scn_path = ""
end)

test("activate() initializes 12-column grid layout correctly", function()
    local widgets = {}
    local orig_dialog = _G.vlc.dialog
    _G.vlc.dialog = function(title)
        local d = {
            title = title,
            add_button = function(self, text, fn, col, row, col_span, row_span)
                table.insert(widgets, { type = "button", text = text, col = col, row = row, col_span = col_span or 1, row_span = row_span or 1 })
                return {}
            end,
            add_label = function(self, text, col, row, col_span, row_span)
                table.insert(widgets, { type = "label", text = text, col = col, row = row, col_span = col_span or 1, row_span = row_span or 1 })
                return { set_text = function() end }
            end,
            add_text_input = function(self, text, col, row, col_span, row_span)
                table.insert(widgets, { type = "text_input", text = text, col = col, row = row, col_span = col_span or 1, row_span = row_span or 1 })
                return { get_text = function() return text end, set_text = function() end }
            end,
            add_dropdown = function(self, col, row, col_span, row_span)
                table.insert(widgets, { type = "dropdown", col = col, row = row, col_span = col_span or 1, row_span = row_span or 1 })
                return { clear = function() end, add_value = function() end, get_value = function() return 0 end }
            end,
            add_list = function(self, col, row, col_span, row_span)
                table.insert(widgets, { type = "list", col = col, row = row, col_span = col_span or 1, row_span = row_span or 1 })
                return { clear = function() end, add_value = function() end, get_selection = function() return {} end }
            end,
            add_html = function(self, text, col, row, col_span, row_span)
                table.insert(widgets, { type = "html", text = text, col = col, row = row, col_span = col_span or 1, row_span = row_span or 1 })
                return { get_text = function() return text end, set_text = function() end }
            end,
            delete = function() end
        }
        return d
    end

    -- Reset app.dlg to force activate to run
    T.app.dlg = nil
    T.activate()

    assert_true(T.app.dlg ~= nil, "Dialog was created")
    assert_eq(#widgets, 22, "All 22 widgets registered in grid")

    -- Primary default button: widgets[1] must be Add/Save Scene button so Qt handles Enter key
    assert_eq(widgets[1].type, "button", "First registered widget is a button")
    assert_eq(widgets[1].row, 16, "First registered button is placed at row 16")
    assert_eq(widgets[1].col, 9, "First registered button is placed at col 9")
    assert_eq(widgets[1].col_span, 4, "First registered button spans 4 cols")

    -- Verify all rows respect 12 columns
    for _, w in ipairs(widgets) do
        assert_true(w.col + w.col_span - 1 <= 12, string.format("Widget %s at row %d fits in 12 columns", w.type, w.row))
    end

    -- Verify Row 1: Active Media Banner (Label spanning 12 columns)
    local r1_media
    for _, w in ipairs(widgets) do
        if w.row == 1 and w.type == "label" then r1_media = w end
    end
    assert_true(r1_media ~= nil, "Row 1 Active Media banner found")
    assert_eq(r1_media.col_span, 12, "Row 1 Active Media banner spans 12 columns")

    -- Verify Row 2: Work Dir input (span 9) & Set Dir button (span 3)
    local r2_btn, r2_inp
    for _, w in ipairs(widgets) do
        if w.row == 2 and w.type == "button" then r2_btn = w end
        if w.row == 2 and w.type == "text_input" then r2_inp = w end
    end
    assert_true(r2_btn ~= nil, "Row 2 Set Dir button found")
    assert_eq(r2_btn.col_span, 3, "Row 2 Set Dir button spans 3 columns")
    assert_true(r2_inp ~= nil, "Row 2 workdir_input found")
    assert_eq(r2_inp.col_span, 9, "Row 2 workdir_input spans 9 columns")

    -- Verify Row 3: .scn path input (span 9) & Set .scn button (span 3)
    local r3_btn, r3_inp
    for _, w in ipairs(widgets) do
        if w.row == 3 and w.type == "button" then r3_btn = w end
        if w.row == 3 and w.type == "text_input" then r3_inp = w end
    end
    assert_true(r3_btn ~= nil, "Row 3 Set .scn button found")
    assert_eq(r3_btn.col_span, 3, "Row 3 Set .scn button spans 3 columns")
    assert_true(r3_inp ~= nil, "Row 3 path_input found")
    assert_eq(r3_inp.col_span, 9, "Row 3 path_input spans 9 columns")
    assert_eq(r3_inp.text, "sample_movie.scn", "path_input displays relative filename when inside work_dir")

    -- Verify Rows 4-11: Scenes List view (Row 4, height 8, width 12)
    local list_w
    for _, w in ipairs(widgets) do
        if w.type == "list" then list_w = w end
    end
    assert_true(list_w ~= nil, "Scenes list widget found")
    assert_eq(list_w.row, 4, "List starts at row 4")
    assert_eq(list_w.row_span, 8, "List spans 8 rows")
    assert_eq(list_w.col_span, 12, "List spans 12 columns")

    -- Verify Row 12: 4 equal buttons spanning 3 columns each
    local r12_buttons = {}
    for _, w in ipairs(widgets) do
        if w.row == 12 and w.type == "button" then table.insert(r12_buttons, w) end
    end
    assert_eq(#r12_buttons, 4, "Row 12 has 4 scene buttons")
    for _, b in ipairs(r12_buttons) do
        assert_eq(b.col_span, 3, string.format("Row 12 button '%s' spans 3 columns", b.text))
    end

    -- Verify Row 13: 2 equal buttons spanning 6 columns each
    local r13_buttons = {}
    for _, w in ipairs(widgets) do
        if w.row == 13 and w.type == "button" then table.insert(r13_buttons, w) end
    end
    assert_eq(#r13_buttons, 2, "Row 13 has 2 FFmpeg buttons")
    for _, b in ipairs(r13_buttons) do
        assert_eq(b.col_span, 6, string.format("Row 13 button '%s' spans 6 columns", b.text))
    end

    -- Verify input field labels (Rows 14-16) align flush left at col 1 and span 2 columns
    for _, w in ipairs(widgets) do
        if w.type == "label" and w.row > 1 then
            assert_eq(w.col, 1, string.format("Label '%s' at row %d starts at col 1", w.text, w.row))
            assert_eq(w.col_span, 2, string.format("Label '%s' at row %d spans 2 columns", w.text, w.row))
        end
    end

    -- Verify Row 17: Status box (html, span 12)
    local r17_status
    for _, w in ipairs(widgets) do
        if w.row == 17 and w.type == "html" then r17_status = w end
    end
    assert_true(r17_status ~= nil, "Row 17 Status box found")
    assert_eq(r17_status.col_span, 12, "Row 17 Status box spans 12 columns")

    -- Clean up
    T.app.dlg = nil
    _G.vlc.dialog = orig_dialog
end)

test("Enter key routing: default dialog button invokes on_save_scene()", function()
    local orig_dialog = _G.vlc.dialog
    local default_btn_cb = nil
    local add_save_caption = nil

    _G.vlc.dialog = function(title)
        local btn_count = 0
        return {
            title = title,
            add_button = function(self, text, fn, col, row, col_span, row_span)
                btn_count = btn_count + 1
                if btn_count == 1 then
                    default_btn_cb = fn
                    add_save_caption = text
                end
                return {}
            end,
            add_label = function() return { set_text = function() end } end,
            add_text_input = function(self, text)
                local val = text or ""
                return {
                    get_text = function() return val end,
                    set_text = function(self, t) val = t end
                }
            end,
            add_list = function()
                return { clear = function() end, add_value = function() end, get_selection = function() return {} end }
            end,
            add_html = function()
                return { get_text = function() return "" end, set_text = function() end }
            end,
            delete = function() end
        }
    end

    T.app.dlg = nil
    T.activate()

    assert_true(default_btn_cb ~= nil, "Default button callback captured")
    assert_true(add_save_caption ~= nil, "Default button caption present")

    -- Setup a valid scene in inputs
    local tmp_scn = Platform.script_ext() == ".bat" and (os.getenv("TEMP") or ".") .. "\\test_enter.scn" or "/tmp/test_enter.scn"
    pcall(os.remove, tmp_scn)
    T.app.path_input:set_text(tmp_scn)
    T.app.loaded_scn_path = tmp_scn
    T.app.repo:clear()

    T.app.start_input:set_text("00:00:10,000")
    T.app.end_input:set_text("00:00:20,000")
    T.app.title_input:set_text("Scene Added via Enter Key")

    -- Simulate pressing Enter (which in Qt QDialog activates the default button)
    default_btn_cb()

    assert_eq(T.app.repo:count(), 1, "Scene saved to repository via default button callback")
    local scn = T.app.repo:get_by_id(1)
    assert_eq(scn.title, "Scene Added via Enter Key", "Scene title matches entered title")
    assert_eq(T.app.title_input:get_text(), "", "Title input cleared after save")

    -- Clean up
    pcall(os.remove, tmp_scn)
    T.app.dlg = nil
    _G.vlc.dialog = orig_dialog
end)

test("Modular architecture: direct require of src/ modules", function()
    local orig_path = package.path
    package.path = "src/?.lua;src/?/init.lua;" .. package.path

    local ModTimeCode = require("timecode")
    local tc = ModTimeCode.from_seconds(125.5)
    assert_eq(tc:to_string(true, ","), "00:02:05,500", "Directly required TimeCode functions")

    local ModPlatform = require("platform")
    assert_true(ModPlatform.quote ~= nil, "Directly required Platform functions")

    local ModScene = require("scene")
    local sc = ModScene.new(1, tc, ModTimeCode.from_seconds(130), "Modular Scene")
    assert_eq(sc.title, "Modular Scene", "Directly required Scene functions")

    local ModRepo = require("scene_repository")
    local repo = ModRepo.new()
    assert_eq(repo:count(), 0, "Directly required SceneRepository functions")

    package.path = orig_path
end)

test("Locale catalog parity: en.lua and ru.lua have matching keys", function()
    local en_chunk = loadfile("src/locales/en.lua") or loadfile("../src/locales/en.lua")
    assert_true(en_chunk ~= nil, "en.lua must be loadable")
    local en = en_chunk()
    assert_true(type(en) == "table", "en.lua returns table")

    local ru_chunk = loadfile("src/locales/ru.lua") or loadfile("../src/locales/ru.lua")
    assert_true(ru_chunk ~= nil, "ru.lua must be loadable")
    local ru = ru_chunk()
    assert_true(type(ru) == "table", "ru.lua returns table")

    local en_keys = 0
    for k, v in pairs(en) do
        en_keys = en_keys + 1
        assert_true(ru[k] ~= nil, string.format("Key '%s' present in en.lua must exist in ru.lua", k))
        assert_true(type(ru[k]) == "string" and #ru[k] > 0, string.format("Key '%s' in ru.lua must be non-empty string", k))
    end

    local ru_keys = 0
    for k, v in pairs(ru) do
        ru_keys = ru_keys + 1
        assert_true(en[k] ~= nil, string.format("Key '%s' present in ru.lua must exist in en.lua", k))
        assert_true(type(en[k]) == "string" and #en[k] > 0, string.format("Key '%s' in en.lua must be non-empty string", k))
    end

    assert_eq(en_keys, ru_keys, "Catalogs must have identical key count")
    assert_true(en_keys >= 40, "Catalogs must contain all required translation keys")
end)

test("Build micro-bundler supports locale module injection (ru)", function()
    local test_out = "dist/reel-maker-ru-test.lua"
    local exit_code = os.execute("luajit scripts/build.lua ru " .. test_out .. " >/dev/null 2>&1")
    assert_true(exit_code == 0 or exit_code == true, "scripts/build.lua ru exits cleanly")

    local f = io.open(test_out, "r")
    assert_true(f ~= nil, "Output bundle must exist")
    f:close()

    local ru_chunk, err = loadfile(test_out)
    assert_true(ru_chunk ~= nil, "Generated Russian bundle must be valid Lua syntax: " .. tostring(err))

    -- Execute in isolated sandbox table
    local env = {}
    for k, v in pairs(_G) do env[k] = v end
    if setfenv then
        setfenv(ru_chunk, env)
    end
    ru_chunk()

    local desc = env.descriptor and env.descriptor() or _G.descriptor()
    assert_true(desc ~= nil and desc.title == "ReelMaker v1.2", "Descriptor title in Russian bundle is ReelMaker v1.2")
    assert_true(desc ~= nil and desc.shortdesc == "ReelMaker v1.2", "Descriptor shortdesc in Russian bundle is ReelMaker v1.2")
    assert_true(desc ~= nil and desc.version == "1.2", "Descriptor version in Russian bundle is 1.2")

    local m = env.menu and env.menu() or _G.menu()
    assert_true(m ~= nil and m[1]:find("Отметить начало", 1, true) ~= nil, "Menu in Russian bundle is localized")

    local L_ru = env.require and env.require("locale")
    assert_true(L_ru ~= nil and L_ru.table_header:find("№", 1, true) ~= nil, "Table header in Russian bundle uses №")

    os.remove(test_out)
end)

pcall(os.remove, test_bundle)
pcall(os.remove, "../" .. test_bundle)

print("--------------------------------------------------")
print(string.format("Test Results: %d/%d passed (%s)", passed_tests, total_tests, passed_tests == total_tests and "ALL PASSED" or "SOME FAILED"))
print("--------------------------------------------------")

if passed_tests ~= total_tests then
    os.exit(1)
end
