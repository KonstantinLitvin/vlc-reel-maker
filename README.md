<p align="center">
  <img src="assets/logo.png" width="180" alt="ReelMaker Logo" />
</p>

# ReelMaker

[English](README.md) | [Русский](README.ru.md)

A VLC media player extension for marking audio and video fragments and navigating between them.
Scene timestamps and titles are saved in `.scn` files. Marked fragments can be cut into separate files with FFmpeg, or exported as a script for customization and later cutting.

---

## Features

- **⏱️ Mark Start / Mark End**: Capture playback timestamps with millisecond precision while watching or listening.
- **✏️ Scene Editing**: Select a scene and click **Edit** to change its timestamps or title, then save with **Add / Save Scene** or **Enter**.
- **✂️ FFmpeg Cutting Without Re-encoding**:
  - **Cut Selected Scenes**: Save one or more selected fragments as separate files.
  - **Export Cut Script**: Generate a script (`.sh` for Linux or `.bat` for Windows) for batch cutting.
- **🌐 Bilingual Interface**: English and Russian (`ru`) builds.
- **💻 Linux and Windows Support**: Includes FFmpeg setup for VLC Snap on Linux and batch scripts for Windows.

---

## Installation

Pre-compiled extension bundles are already provided in `dist/`.

### Windows

#### Option 1: Installer Wizard (Recommended)
Download and run the setup wizard from [GitHub Releases](https://github.com/KonstantinLitvin/vlc-reel-maker/releases):
* `ReelMaker-Setup-v1.2.exe`

*(Supports English & Russian, installs the extension into VLC, and offers optional one-click FFmpeg setup).*

#### Option 2: 1-Click Batch Installer (Portable / Cloned Repo)
If you cloned the repository or downloaded the ZIP:
```cmd
scripts\install-windows.bat
```
*(Prompts for language: English or Russian, installs `reel-maker.lua` into `%APPDATA%\vlc\lua\extensions\`, and verifies FFmpeg).*

#### Manual Copy
Copy `dist/reel-maker.lua` to:
```cmd
%APPDATA%\vlc\lua\extensions\reel-maker.lua
```

---

### Linux

Run the installation script:
```bash
./scripts/install.sh        # Default: English
./scripts/install.sh ru     # Russian build
```

Or manually copy `dist/reel-maker.lua` to:
- **Snap VLC**: `~/snap/vlc/current/.local/share/vlc/lua/extensions/`
- **Native VLC**: `~/.local/share/vlc/lua/extensions/`

---

### 3. FFmpeg Setup (For Direct In-App Cutting)

The extension provides two ways to cut media:
1. **Export Cut Script (`[ 🎬 Export Cut Script ]`)**: Creates a script (`.sh` or `.bat`) in the working directory for running in a terminal. Exporting does not require FFmpeg inside VLC; running the script requires `ffmpeg` in the terminal’s `PATH`.
2. **Direct Cutting (`[ ✂️ Cut ]`)**: Requires FFmpeg to be accessible to VLC.

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
   - Click `[ ⏱️ Mark ]` beside **Start** at the beginning of the fragment.
   - Click `[ ⏱️ Mark ]` beside **End** at the end of the fragment.
   - Enter a title (or leave blank for auto-generated `Scene N`).
   - Click `[ ➕ Add / Save Scene ]` or press **Enter** in the title field.
5. **Managing Selected Scenes**:
   - Select one or more scenes in the list (Ctrl/Shift for multiple selection):
     - `[ ⏮️ To Start ]`: Moves playback to the start of a single selected scene.
     - `[ ⏭️ To End ]`: Moves playback to the end of a single selected scene.
     - `[ ✏️ Edit ]`: Loads a single selected scene into the input fields. Click `[ ➕ Add / Save Scene ]` or press **Enter** to save; click `[ ✏️ Edit ]` again to cancel.
     - `[ ✂️ Cut ]`: Cuts the selected scenes without re-encoding and saves them in the working directory. Multiple scenes are processed in sequence with progress messages.
     - `[ 🗑️ Delete ]`: Deletes selected scenes, renumbers the remaining scenes, and saves the `.scn` file. When deleting multiple scenes, click **Delete** again to confirm.
6. **Batch Export**:
   - Click `[ 🎬 Export Cut Script ]` to create a cut script in the working directory. It includes the selected scenes, or all scenes if none are selected. The filename includes the media name and, when different, the `.scn` name (for example, `movie_highlights_cut_scenes.sh` or `.bat`).

---

## Development & Building from Source

The modular source code is located in `src/`. Pre-compiled single-file bundles are already provided in `dist/`. If you modify code in `src/`, compile bundles using:

### Linux / macOS
```bash
./scripts/build.sh          # Default: builds all bundles (English default)
./scripts/build.sh ru       # Russian build only
```

### Windows (Command Prompt / PowerShell)
```cmd
scripts\build.bat           # Default: builds all bundles (English default)
scripts\build.bat ru        # Russian build only
```
*(or directly with Lua/LuaJIT: `luajit scripts/build.lua`)*

### Building Windows Setup Executable (.exe)
Requires [Inno Setup 6](https://jrsoftware.org/isdl.php):
```cmd
iscc scripts\reel-maker.iss
```

---

## Running Tests

Run the test suite without the VLC graphical interface using LuaJIT:

```bash
luajit tests/test_reel_maker.lua
```

## License

MIT License. Copyright (c) 2026 Konstantin Litvin. See [LICENSE](LICENSE).
