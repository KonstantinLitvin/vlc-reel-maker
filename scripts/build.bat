@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%..\"

cd /d "%ROOT_DIR%"

where luajit.exe >nul 2>&1
if not errorlevel 1 (
    luajit "%SCRIPT_DIR%build.lua" %*
    goto :done
)

where lua.exe >nul 2>&1
if not errorlevel 1 (
    lua "%SCRIPT_DIR%build.lua" %*
    goto :done
)

echo [ERROR] Neither luajit nor lua was found in your PATH.
echo Please install Lua or LuaJIT to build the extension bundles on Windows.
exit /b 1

:done
endlocal
