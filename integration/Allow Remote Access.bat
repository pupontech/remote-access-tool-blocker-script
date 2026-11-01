@echo off
setlocal
set "SCRIPT=%~dp0Start-Here.ps1"
if exist "%SCRIPT%" goto run
 echo Start-Here.ps1 was not found next to this launcher.
 pause
 exit /b 1
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Allow
set "RC=%errorlevel%"
exit /b %RC%
