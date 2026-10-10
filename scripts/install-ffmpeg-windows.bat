@echo off
setlocal

REM Windows FFmpeg installer / setup for VLC ReelMaker
REM Checks for bundled ffmpeg, existing ffmpeg, attempts winget install, or downloads to %APPDATA%\vlc\bin

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

REM Option 1: Check if ffmpeg.exe exists locally in the package folder
set "LOCAL_FFMPEG="
if exist "%~dp0ffmpeg.exe" set "LOCAL_FFMPEG=%~dp0ffmpeg.exe"
if exist "%~dp0dist\ffmpeg.exe" set "LOCAL_FFMPEG=%~dp0dist\ffmpeg.exe"
if exist "%~dp0..\dist\ffmpeg.exe" set "LOCAL_FFMPEG=%~dp0..\dist\ffmpeg.exe"

if defined LOCAL_FFMPEG (
    echo Option 1: Found local ffmpeg.exe at "%LOCAL_FFMPEG%"
    set "TARGET_DIR=%APPDATA%\vlc\bin"
    if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
    copy /y "%LOCAL_FFMPEG%" "%TARGET_DIR%\ffmpeg.exe" >nul
    set "EXT_DIR=%APPDATA%\vlc\lua\extensions"
    if not exist "%EXT_DIR%" mkdir "%EXT_DIR%"
    copy /y "%LOCAL_FFMPEG%" "%EXT_DIR%\ffmpeg.exe" >nul
    if exist "%TARGET_DIR%\ffmpeg.exe" (
        echo [OK] Successfully copied ffmpeg.exe to "%TARGET_DIR%\ffmpeg.exe".
        goto :done
    )
)

REM Option 2: Try winget (interactive only)
if "%NON_INTERACTIVE%"=="1" goto :try_download
where winget.exe >nul 2>&1
if errorlevel 1 goto :try_download

echo Option 2: Attempting installation via winget...
winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements
if not errorlevel 1 (
    echo [OK] Successfully installed FFmpeg via winget.
    echo Please restart VLC to pick up the updated PATH.
    goto :done
)
echo Winget installation failed. Falling back to standalone download...

:try_download
echo.
echo Option 3: Downloading standalone FFmpeg to %APPDATA%\vlc\bin\...
set "TARGET_DIR=%APPDATA%\vlc\bin"
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"

set "PS1_HELPER=%~dp0download-ffmpeg.ps1"
if not exist "%PS1_HELPER%" set "PS1_HELPER=%~dp0..\scripts\download-ffmpeg.ps1"

if exist "%PS1_HELPER%" (
    if "%NON_INTERACTIVE%"=="1" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_HELPER%" > "%TEMP%\vlc_ffmpeg_setup.log" 2>&1
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_HELPER%"
    )
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288; " ^
      "$u = 'https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip'; " ^
      "$z = \"$env:TEMP\ffmpeg.zip\"; $e = \"$env:TEMP\ffmpeg_ext\"; " ^
      "(New-Object System.Net.WebClient).DownloadFile($u, $z); " ^
      "Expand-Archive -Path $z -DestinationPath $e -Force; " ^
      "$b = Get-ChildItem -Path $e -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1; " ^
      "Copy-Item $b.FullName -Destination \"$env:APPDATA\vlc\bin\ffmpeg.exe\" -Force; " ^
      "Remove-Item $z -Force -ErrorAction SilentlyContinue; " ^
      "Remove-Item $e -Recurse -Force -ErrorAction SilentlyContinue"
)

if exist "%APPDATA%\vlc\bin\ffmpeg.exe" (
    echo [OK] FFmpeg setup succeeded: %APPDATA%\vlc\bin\ffmpeg.exe
) else (
    echo [WARNING] Automatic download failed.
    echo You can manually download ffmpeg from https://ffmpeg.org/download.html and add it to %APPDATA%\vlc\bin\
)

:done
echo ==================================================
echo Setup complete. Restart VLC and open View -^> ReelMaker.
echo ==================================================
if "%NON_INTERACTIVE%"=="0" pause
endlocal
