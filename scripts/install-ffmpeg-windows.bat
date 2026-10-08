@echo off
setlocal

REM Windows FFmpeg installer / setup for VLC ReelMaker
REM Checks for existing ffmpeg, attempts winget install, or downloads to %APPDATA%\vlc\bin

set "NON_INTERACTIVE=0"
if /i "%~1"=="--silent" set "NON_INTERACTIVE=1"
if /i "%~1"=="/silent" set "NON_INTERACTIVE=1"
if /i "%~1"=="-s" set "NON_INTERACTIVE=1"
if /i "%~1"=="-y" set "NON_INTERACTIVE=1"
if /i "%~1"=="--non-interactive" set "NON_INTERACTIVE=1"

echo ==================================================
echo Checking FFmpeg for VLC ReelMaker (Windows)
echo ==================================================

REM Check if ffmpeg is in PATH
where ffmpeg.exe >nul 2>&1
if not errorlevel 1 (
    echo [OK] FFmpeg is already installed and available in PATH:
    where ffmpeg.exe
    goto :done
)

REM Check dedicated VLC tools directory
if exist "%APPDATA%\vlc\bin\ffmpeg.exe" (
    echo [OK] FFmpeg found in dedicated directory: %APPDATA%\vlc\bin\ffmpeg.exe
    goto :done
)

echo FFmpeg is not found in PATH or %APPDATA%\vlc\bin\.
echo.

REM Option 1: Try winget
where winget.exe >nul 2>&1
if errorlevel 1 goto :try_download

echo Option 1: Attempting installation via winget...
winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements
if not errorlevel 1 (
    echo [OK] Successfully installed FFmpeg via winget.
    echo Please restart VLC to pick up the updated PATH.
    goto :done
)
echo Winget installation failed. Falling back to standalone download...

:try_download
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
    echo [OK] FFmpeg setup succeeded.
) else (
    echo [WARNING] Automatic download failed. You can manually download ffmpeg from:
    echo https://ffmpeg.org/download.html and add it to your PATH.
)

:done
echo ==================================================
echo Setup complete. Restart VLC and open View -> ReelMaker.
echo ==================================================
if "%NON_INTERACTIVE%"=="0" pause
endlocal
