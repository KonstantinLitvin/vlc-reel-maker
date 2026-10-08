@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul

REM ==================================================
REM VLC ReelMaker Extension Installer (Windows)
REM Installs ReelMaker to VLC Media Player
REM Usage: install-windows.bat [ru|en]
REM ==================================================

echo ==================================================
echo   VLC ReelMaker Extension Installer for Windows
echo ==================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%..\"

REM 1. Target Directory Detection
set "TARGET_DIR=%APPDATA%\vlc\lua\extensions"
if not exist "%TARGET_DIR%" (
    echo [*] Creating VLC extensions directory:
    echo     %TARGET_DIR%
    mkdir "%TARGET_DIR%" 2>nul
    if errorlevel 1 (
        echo [ERROR] Failed to create directory: %TARGET_DIR%
        pause
        exit /b 1
    )
)

REM 2. Language Selection
set "LANG_OPT=%~1"
if /i "%LANG_OPT%"=="ru" goto :set_ru
if /i "%LANG_OPT%"=="en" goto :set_en

echo Choose language / Выберите язык:
echo [1] Русский (Russian)
echo [2] English
echo.
set /p "CHOICE=Enter choice (1-2, default=1): "
if "%CHOICE%"=="2" goto :set_en

:set_ru
set "SRC_BUNDLE=%ROOT_DIR%dist\reel-maker-ru.lua"
if not exist "%SRC_BUNDLE%" set "SRC_BUNDLE=%ROOT_DIR%dist\reel-maker.lua"
echo [*] Selected: Russian
goto :install_bundle

:set_en
set "SRC_BUNDLE=%ROOT_DIR%dist\reel-maker-en.lua"
if not exist "%SRC_BUNDLE%" set "SRC_BUNDLE=%ROOT_DIR%dist\reel-maker.lua"
echo [*] Selected: English
goto :install_bundle

:install_bundle
if not exist "%SRC_BUNDLE%" (
    echo [ERROR] Distribution bundle not found: %SRC_BUNDLE%
    echo Please ensure the project repository is intact.
    pause
    exit /b 1
)

REM 3. Clean up legacy file
if exist "%TARGET_DIR%\scene-marker.lua" (
    echo [*] Removing legacy extension scene-marker.lua...
    del /f /q "%TARGET_DIR%\scene-marker.lua" 2>nul
)

REM 4. Copy Bundle
echo [*] Copying extension file...
copy /Y "%SRC_BUNDLE%" "%TARGET_DIR%\reel-maker.lua" >nul
if errorlevel 1 (
    echo [ERROR] Failed to copy %SRC_BUNDLE% to %TARGET_DIR%\reel-maker.lua
    pause
    exit /b 1
)
echo [OK] Extension installed to:
echo      %TARGET_DIR%\reel-maker.lua
echo.

REM 5. Check Global VLC Program Files Directory (Optional install)
if exist "%ProgramFiles%\VideoLAN\VLC\" (
    set "GLOBAL_DIR=%ProgramFiles%\VideoLAN\VLC\lua\extensions"
    if not exist "!GLOBAL_DIR!" mkdir "!GLOBAL_DIR!" 2>nul
    copy /Y "%SRC_BUNDLE%" "!GLOBAL_DIR!\reel-maker.lua" >nul 2>nul
    if not errorlevel 1 (
        echo [OK] Also installed globally to:
        echo      !GLOBAL_DIR!\reel-maker.lua
        if exist "!GLOBAL_DIR!\scene-marker.lua" del /f /q "!GLOBAL_DIR!\scene-marker.lua" 2>nul
        echo.
    )
)

REM 6. Check FFmpeg availability
where ffmpeg.exe >nul 2>&1
set "FFMPEG_IN_PATH=!errorlevel!"
if !FFMPEG_IN_PATH! EQU 0 (
    echo [OK] FFmpeg is already installed and available in PATH.
) else if exist "%APPDATA%\vlc\bin\ffmpeg.exe" (
    echo [OK] FFmpeg is installed in: %APPDATA%\vlc\bin\ffmpeg.exe
) else (
    echo [INFO] FFmpeg was not detected in PATH or %APPDATA%\vlc\bin\.
    echo        Direct in-app lossless cutting requires FFmpeg.
    echo.
    set /p "RUN_FFMPEG=Would you like to install FFmpeg now? (Y/N, default=Y): "
    if "!RUN_FFMPEG!"=="" set "RUN_FFMPEG=Y"
    if /i "!RUN_FFMPEG!"=="Y" (
        if exist "%SCRIPT_DIR%install-ffmpeg-windows.bat" (
            call "%SCRIPT_DIR%install-ffmpeg-windows.bat"
        )
    )
)

echo.
echo ==================================================
echo   Installation complete!
echo   Restart VLC Media Player, then open:
echo   View -^> ReelMaker v1.2 (or Вид -^> ReelMaker v1.2)
echo ==================================================
pause
endlocal
