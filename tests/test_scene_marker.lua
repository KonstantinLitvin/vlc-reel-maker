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
    assert_eq(repo2:count(), 3, "Re-read count matches 3")
    assert_eq(repo2:get_by_id(2).title, "Middle Scene", "Re-read ID lookup matches")

    os.remove(tmp_path)
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
    assert_true(content:find("ffmpeg -y", 1, true) ~= nil, "Script contains ffmpeg command")

    os.remove(path)
end)

-- 6. VlcPlayerAdapter tests
test("VlcPlayerAdapter: get_current_time and guess_scn_path", function()
    local tc, err = VlcPlayerAdapter.get_current_time()
    assert_true(tc ~= nil, "Current time returned: " .. tostring(err))
    assert_eq(tc:to_string(true, ","), "00:01:15,450", "Microseconds accurately converted")

    local scn_path = VlcPlayerAdapter.guess_scn_path()
    assert_eq(scn_path, "/home/user/Videos/sample_movie.scn", "Guessed .scn path correctly")
end)

print("--------------------------------------------------")
print(string.format("Test Results: %d/%d passed (%s)", passed_tests, total_tests, passed_tests == total_tests and "ALL PASSED" or "SOME FAILED"))
print("--------------------------------------------------")

if passed_tests ~= total_tests then
    os.exit(1)
end
