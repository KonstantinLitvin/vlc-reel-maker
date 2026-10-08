<p align="center">
  <img src="assets/logo.png" width="180" alt="ReelMaker Logo" />
</p>

# ReelMaker

[English](README.md) | [Русский](README.ru.md)

A modern, high-precision VLC media player extension written in Lua for media fragment capture, highlight reel navigation, `.scn` file persistence, and lossless FFmpeg cutting.

---

## Features

- **⏱️ Mark In & Mark Out**: Capture current playback timestamps with millisecond accuracy directly from playing video or audio media.
- **💾 Automatic `.scn` Persistence**: Auto-guesses the `.scn` file location based on media file path, parses subtitle-like scene blocks, and saves updates.
- **🔄 Auto-Sorting & Reindexing**: Newly captured scenes are sorted chronologically and assigned sequential IDs (`№ 1..N`).
- **✏️ In-Place Scene Editing**: Select any scene and click **Edit** to populate Start, End, and Title fields, adjust boundaries or text, and update via the dual-mode **Add / Save Scene** button.
- **▶ Non-Blocking Navigation**: Jump to scene Start or End timestamps instantly without VLC interface thread locks.
- **✂️ FFmpeg Media Cutting**:
  - **Cut Selected Scene**: Executes an ultra-fast, lossless stream copy (`-c copy`) with verified exit status, output file validation, and error log diagnostics.
  - **Export Cut Script**: Generates a self-contained batch script (`.sh` for Linux or `.bat` for Windows) next to your media for one-click processing.
- **🌐 Dual-Language Localization**: Full build-stage localization for English and Russian (`ru`), including localized table headers with `№` notation.
- **💻 Cross-Platform Compatibility**: Full support for Linux (POSIX shell, Snap confinement) and Windows (`cmd.exe` batch files, `start /B` background tasks).

---

## Installation & Build

### 1. Build Bundle
The source code is organized into modular Lua components under `src/`. To compile them into `dist/reel-maker.lua`:
```bash
./scripts/build.sh          # Default: English
./scripts/build.sh ru       # Russian build
```

### 2. Extension Installation

#### Linux
Run the installation script (which automatically builds and installs `dist/reel-maker.lua`):
```bash
./scripts/install.sh        # Install default English build
./scripts/install.sh ru     # Install Russian build
```
Or manually copy `dist/reel-maker.lua` to:
- **Snap VLC**: `~/snap/vlc/current/.local/share/vlc/lua/extensions/`
- **Native VLC**: `~/.local/share/vlc/lua/extensions/`

#### Windows
Copy `dist/reel-maker.lua` to:
```
%APPDATA%\vlc\lua\extensions\reel-maker.lua
```

---

### 3. FFmpeg Setup (For Direct In-App Cutting)

The extension provides two ways to cut media:
1. **Export Cut Script (`[ 📄 Export Cut Script ]`)**: Requires no setup inside VLC. Writes a batch script (`.sh` or `.bat`) next to your video/audio file that runs on your host machine.
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

1. Open VLC Media Player and start playing a media file (video or audio).
2. In the menu bar, open: **View** -> **ReelMaker v1.2** (or **Вид** -> **ReelMaker v1.2**).
3. **Working Directory & File Path**:
   - **Work Dir**: Auto-detected from playing media directory. Specify a custom folder to save cut clips and exported scripts elsewhere.
   - **.scn File**: Auto-detected `.scn` path. If an `.scn` file already exists, it is loaded automatically.
4. **Marking a Fragment**:
   - Click `[ ⏱️ Mark Start ]` at the fragment start.
   - Click `[ ⏱️ Mark End ]` at the fragment end.
   - Enter a title (or leave blank for auto-generated `Scene N`).
   - Click `[ ➕ Add / Save Scene ]`.
5. **Managing Selected Scenes**:
   - Select any scene row in the list to enable the action toolbar:
     - `[ ▶ To Start ]`: Seeks playback to the scene start.
     - `[ ⏹ To End ]`: Seeks playback to the scene end.
     - `[ ✏️ Edit ]`: Loads the selected scene into the input fields for in-place editing; click `[ ➕ Add / Save Scene ]` to update or `[ ✏️ Edit ]` again to cancel.
     - `[ ✂️ Cut ]`: Cuts the selected scene(s) synchronously using FFmpeg into your working directory (supports selecting multiple scenes with Ctrl/Shift for batch cutting with live GUI progress).
     - `[ 🗑️ Delete ]`: Atomically removes the selected scene(s), reindexes remaining scenes sequentially, and updates the `.scn` file (includes 2-step confirmation prompt when deleting multiple scenes).
6. **Batch Export**:
   - Click `[ 📄 Export Cut Script ]` to create a `movie_cut_scenes.sh` (or `.bat`) batch script inside your working directory.

---

## Running Tests

The test suite runs headlessly using `luajit` or standard `lua5.1` / `lua5.2`:

```bash
luajit tests/test_reel_maker.lua
```
