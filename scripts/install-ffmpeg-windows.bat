@echo off
setlocal enabledelayedexpansion

REM Windows FFmpeg installer / setup for VLC Scene Marker
REM Checks for existing ffmpeg, attempts winget install, or downloads to %APPDATA%\vlc\bin

echo ==================================================
echo Checking FFmpeg for VLC Scene Marker (Windows)
echo ==================================================

where ffmpeg.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [OK] FFmpeg is already installed and available in PATH:
    where ffmpeg.exe
    goto :done
)

if exist "%APPDATA%\vlc\bin\ffmpeg.exe" (
    echo [OK] FFmpeg found in dedicated directory: %APPDATA%\vlc\bin\ffmpeg.exe
    goto :done
)

echo FFmpeg is not found in PATH or %APPDATA%\vlc\bin\.
echo.
echo Option 1: Attempting installation via winget...
where winget.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements
    if %ERRORLEVEL% equ 0 (
        echo [OK] Successfully installed FFmpeg via winget!
        echo Please restart VLC to pick up the updated PATH.
        goto :done
    )
)

echo.
echo Option 2: Downloading standalone FFmpeg to %APPDATA%\vlc\bin\...
set "TARGET_DIR=%APPDATA%\vlc\bin"
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$zip = \"$env:TEMP\ffmpeg.zip\"; " ^
  "Write-Host 'Downloading FFmpeg release essentials...'; " ^
  "Invoke-WebRequest -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip; " ^
  "Write-Host 'Extracting ffmpeg.exe...'; " ^
  "Expand-Archive -Path $zip -DestinationPath \"$env:TEMP\ffmpeg_extracted\" -Force; " ^
  "Copy-Item \"$env:TEMP\ffmpeg_extracted\*\bin\ffmpeg.exe\" -Destination \"$env:APPDATA\vlc\bin\ffmpeg.exe\" -Force; " ^
  "Remove-Item $zip -Force; " ^
  "Remove-Item \"$env:TEMP\ffmpeg_extracted\" -Recurse -Force; " ^
  "Write-Host '[OK] Installed ffmpeg.exe to $env:APPDATA\vlc\bin\ffmpeg.exe'"

if exist "%APPDATA%\vlc\bin\ffmpeg.exe" (
    echo [OK] FFmpeg setup succeeded!
) else (
    echo [WARNING] Automatic download failed. You can manually download ffmpeg from:
    echo https://ffmpeg.org/download.html and add it to your PATH.
)

:done
echo ==================================================
echo Setup complete. Restart VLC and open View -> Scene Marker.
echo ==================================================
pause
