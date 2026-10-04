# VLC Scene Marker

A modern, VLC media player extension written in Lua for video fragment capture, scene navigation, `.scn` file persistence, and FFmpeg video cutting.

---

## Features

- **⏱️ Mark In & Mark Out**: Capture current playback timestamps with millisecond accuracy directly from playing media.
- **💾 Automatic `.scn` Persistence**: Auto-guesses the `.scn` file location based on video file path, parses subtitle-like scene blocks, and saves updates.
- **🔄 Auto-Sorting & Reindexing**: Newly captured scenes are sorted chronologically and assigned sequential IDs (1..N).
- **✏️ In-Place Scene Editing**: Select any scene and click **Edit** to populate Start, End, and Title fields, adjust boundaries or text, and update via the dual-mode **Add / Save Scene** button.
- **▶ Non-Blocking Navigation**: Jump to scene Start or End timestamps instantly without VLC interface thread locks.
- **✂️ FFmpeg Video Cutting**:
  - **Cut Selected Scene**: Executes an ultra-fast, lossless stream copy (`-c copy`) with verified exit status, output file validation, and error log diagnostics.
  - **Export Cut Script**: Generates a self-contained batch script (`.sh` for Linux or `.bat` for Windows) next to your video for one-click processing.
- **🌐 Cross-Platform Compatibility**: Full support for Linux (POSIX shell, Snap confinement) and Windows (`cmd.exe` batch files, `start /B` background tasks).

---

## Architecture & Design

The codebase adheres to Clean Architecture and Object-Oriented Domain-Driven Design principles, separating value objects, domain entities, persistence repositories, platform abstractions, and UI presentation.

Detailed documentation, component responsibilities, and class diagrams can be found in:
👉 **[Architecture & Design Documentation](md/architecture.md)**

---

## File Structure

```
scene-maker/
├── src/
│   └── scene-marker.lua            # Standalone extension script for VLC
├── tests/
│   └── test_scene_marker.lua       # Standalone headless test suite
├── scripts/
│   ├── install.sh                  # Installer script for Snap & Native VLC
│   ├── get-ffmpeg.sh               # Downloads static FFmpeg for Snap VLC
│   └── install-ffmpeg-windows.bat  # Automated Windows FFmpeg installer
├── md/
│   └── architecture.md             # Architecture specification and class diagrams
└── README.md                       # Project documentation
```

---

## Installation

### 1. Extension Installation

#### Linux
Run the installation script:
```bash
./scripts/install.sh
```
Or manually copy `src/scene-marker.lua` to:
- **Snap VLC**: `~/snap/vlc/current/.local/share/vlc/lua/extensions/`
- **Native VLC**: `~/.local/share/vlc/lua/extensions/`

#### Windows
Copy `src/scene-marker.lua` to:
```
%APPDATA%\vlc\lua\extensions\scene-marker.lua
```

---

### 2. FFmpeg Setup (For Direct In-App Cutting)

The extension provides two ways to cut videos:
1. **Export Cut Script (`[ 📄 Export Cut Script ]`)**: Requires no setup inside VLC. Writes a batch script (`.sh` or `.bat`) next to your video that runs on your host machine.
2. **Direct In-App Cutting (`[ ✂️ Cut Selected Scene ]`)**: Requires FFmpeg to be accessible to VLC.

#### Linux (VLC Snap)
Ubuntu Snap isolates VLC from host binaries in `/usr/bin`. Install the standalone static FFmpeg build into the Snap's shared environment with one command:
```bash
./scripts/get-ffmpeg.sh
```

#### Windows
On Windows, run the automated setup script:
```cmd
scripts\install-ffmpeg-windows.bat
```
This automatically:
- Checks if FFmpeg is already installed and in `PATH`.
- Installs via `winget install Gyan.FFmpeg` if `winget` is available.
- Or downloads a standalone `ffmpeg.exe` directly to `%APPDATA%\vlc\bin\ffmpeg.exe`.

Alternatively, install manually via winget:
```cmd
winget install Gyan.FFmpeg
```
or place `ffmpeg.exe` into `%APPDATA%\vlc\bin\`.

---

## Usage

1. Open VLC Media Player and start playing a video.
2. In the menu bar, open: **View** -> **Scene Marker** (or right-click the video canvas and choose **Scene Marker** actions from the menu).
3. **Working Directory & File Path**:
   - **Work Dir**: Auto-detected from playing video directory. Specify a custom folder to save cut clips and exported scripts elsewhere.
   - **.scn File**: Auto-detected `.scn` path. If an `.scn` file already exists, it is loaded automatically.
4. **Marking a Fragment**:
   - Click `[ ⏱️ Mark Start (In) ]` at the fragment start.
   - Click `[ ⏱️ Mark End (Out) ]` at the fragment end.
   - Enter a title (or leave blank for auto-generated `Scene N`).
   - Click `[ ➕ Add / Save Scene ]`.
5. **Managing Selected Scenes**:
   - Select any scene row in the list to enable the action toolbar:
     - `[ ▶ To Start ]`: Seeks playback to the scene start.
     - `[ ⏹ To End ]`: Seeks playback to the scene end.
     - `[ ✏️ Edit ]`: Loads the selected scene into the input fields for in-place editing; click `[ ➕ Add / Save Scene ]` to update or `[ ✏️ Edit ]` again to cancel.
     - `[ ✂️ Cut ]`: Cuts the selected fragment synchronously using FFmpeg into your working directory.
     - `[ 🗑️ Delete ]`: Removes the scene, reindexes remaining scenes sequentially, and updates the `.scn` file.
6. **Batch Export**:
   - Click `[ 📄 Export Cut Script ]` to create a `movie_cut_scenes.sh` (or `.bat`) batch script inside your working directory.

---

## Running Tests

The test suite runs headlessly using `luajit` or standard `lua5.1` / `lua5.2`:

```bash
luajit tests/test_scene_marker.lua
```
