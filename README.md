# VLC Scene Marker

A modern, object-oriented VLC media player extension written in Lua for video fragment capture, scene navigation, `.scn` file persistence, and FFmpeg video cutting.

---

## Features

- **⏱️ Mark In & Mark Out**: Capture current playback timestamps with millisecond accuracy directly from playing media.
- **💾 Automatic `.scn` Persistence**: Auto-guesses the `.scn` file location based on video file path, parses subtitle-like scene blocks, and saves updates.
- **🔄 Auto-Sorting & Reindexing**: Newly captured scenes are sorted chronologically and assigned sequential IDs (1..N).
- **▶ Non-Blocking Navigation**: Jump to scene Start or End timestamps instantly without VLC interface thread locks.
- **✂️ FFmpeg Video Cutting**:
  - **Cut Selected Scene**: Executes an asynchronous, lossless stream copy (`-c copy`) in the background.
  - **Export Cut Script**: Generates a self-contained batch script (`.sh` for Linux or `.bat` for Windows) next to your video for one-click processing.
- **🌐 Cross-Platform Compatibility**: Full support for Linux (POSIX shell, Snap confinement) and Windows (`cmd.exe` batch files, `start /B` background tasks).

---

## Architecture & Design

The codebase adheres to Clean Architecture and Object-Oriented Domain-Driven Design principles:

```mermaid
classDiagram
    direction TB

    namespace Domain {
        class TimeCode {
            +number total_sec
            +from_seconds(sec)$ TimeCode
            +from_string(str)$ TimeCode
            +to_string(with_ms, delimiter) string
            +__lt(a, b) boolean
            +__eq(a, b) boolean
        }
        class Scene {
            +number id
            +TimeCode start_tc
            +TimeCode end_tc
            +string title
            +duration() number
            +to_table_row() string
            +to_scn_block() string
        }
    }

    namespace Infrastructure {
        class SceneRepository {
            +list scenes
            +string file_path
            +load(path) tuple
            +save(path) tuple
            +add(start_tc, end_tc, title) tuple
            +sort_and_reindex() void
            +get_by_id(id) Scene
        }
        class Platform {
            +boolean is_windows$
            +quote(str, is_win)$ string
            +bg_command(cmd, log, is_win)$ string
            +script_ext(is_win)$ string
        }
        class CutterService {
            +build_cut_command(video_path, scene, out_path, is_win)$ string
            +generate_script(video_path, scenes, is_win)$ string
            +export_script(video_path, scenes, is_win)$ tuple
            +cut_scene_async(video_path, scene, is_win)$ tuple
        }
        class VlcPlayerAdapter {
            +get_current_time()$ TimeCode
            +seek(tc)$ boolean
            +guess_scn_path()$ string
            +get_video_path()$ string
        }
    }

    namespace Presentation {
        class SceneMarkerApp {
            -SceneRepository repo
            -dialog dlg
            +on_load_file() void
            +on_mark_start() void
            +on_mark_end() void
            +on_add_scene() void
            +on_jump_to_start() void
            +on_jump_to_end() void
            +on_cut_selected() void
            +on_export_script() void
        }
    }

    SceneMarkerApp --> SceneRepository
    SceneMarkerApp --> CutterService
    SceneMarkerApp --> VlcPlayerAdapter
    CutterService --> Platform
    CutterService --> Scene
    SceneRepository *-- Scene
    Scene *-- TimeCode
```

### Components

1. **`TimeCode`** (Value Object): Immutable timestamp representation with fractional millisecond arithmetic, comparison operators (`<`, `<=`, `==`), and flexible delimiter formatting (`:`/`,`/`.`).
2. **`Scene`** (Domain Entity): Invariant validation (`end_time > start_time`), formatting for table rows and `.scn` file format blocks.
3. **`SceneRepository`** (Repository): Streaming `.scn` parser with chronological sorting and atomic writing.
4. **`Platform`** (Infrastructure Abstraction): OS detection via `package.config`, argument quoting, and background execution formatting.
5. **`CutterService`** (Domain Service): Builds lossless FFmpeg commands and exports `.sh` / `.bat` scripts.
6. **`VlcPlayerAdapter`** (Port Adapter): Decouples VLC C-API (`vlc.object.input()`, `vlc.var.get/set`) from the presentation logic.
7. **`SceneMarkerApp`** (Presentation): Manages the VLC dialog lifecycle, inputs, and UI widgets.

---

## File Structure

```
scene-maker/
├── src/
│   └── scene-marker.lua      # Standalone extension script for VLC
├── tests/
│   └── test_scene_marker.lua # Standalone headless test suite
├── scripts/
│   └── install.sh            # Installer script for Snap & Native VLC
└── README.md                 # Project documentation
```

---

## Installation

### Linux
Run the installation script:
```bash
./scripts/install.sh
```
Or manually copy `src/scene-marker.lua` to:
- **Snap VLC**: `~/snap/vlc/current/.local/share/vlc/lua/extensions/`
- **Native VLC**: `~/.local/share/vlc/lua/extensions/`

### Windows
Copy `src/scene-marker.lua` to:
```
%APPDATA%\vlc\lua\extensions\scene-marker.lua
```

---

## Usage

1. Open VLC Media Player and start playing a video.
2. In the menu bar, open: **View** -> **Scene Marker**.
3. The `.scn` file path is auto-detected. If an `.scn` file already exists, it is loaded automatically.
4. **Marking a Fragment**:
   - Click `[ ⏱️ Mark Start (In) ]` at the fragment start.
   - Click `[ ⏱️ Mark End (Out) ]` at the fragment end.
   - Enter a title (or leave blank for auto-generated `Scene N`).
   - Click `[ ➕ Add & Save Scene ]`.
5. **Navigating**:
   - Select a row in the list and click `[ ▶ Jump to Start ]` or `[ ⏹ Jump to End ]`.
6. **Cutting Video**:
   - Click `[ ✂️ Cut Selected Scene ]` to cut the selected fragment in the background.
   - Click `[ 📄 Export Cut Script ]` to create a `movie_cut_scenes.sh` (or `.bat`) batch script right next to your video.

---

## Running Tests

The test suite runs headlessly using `luajit` or standard `lua5.1` / `lua5.2`:

```bash
luajit tests/test_scene_marker.lua
```
