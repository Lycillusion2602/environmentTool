@echo off
REM Launch Environment Manager without a console window.
setlocal
set "VBS=%~dp0launch.vbs"
if not exist "%VBS%" (
    echo [ERROR] launch.vbs not found: %VBS%
    pause
    exit /b 1
)
start "" /b wscript.exe "%VBS%" %*
endlocal
