@echo off
rem Self-elevating launcher for the Windows App Control-only revert tool.
rem   Run-Revert.bat                 undo the block on this PC (asks before it does anything)
rem   Run-Revert.bat -WhatIf         dry run - show every step, change nothing
rem   Run-Revert.bat -Restore        put a previously backed-up block back
rem   Run-Revert.bat -NoPause        do not wait for a key press at the end (remote/unattended)
rem
rem This folder is installed to C:\RemoteAccessToolBlocker by the kit, so this launcher is
rem available on the PC without the original kit or any network access.
setlocal
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Revert-RemoteAccessBlock-WinOnly.v*.ps1" 2^>nul') do if not defined TARGET set "TARGET=%~dp0%%F"
if not defined TARGET goto target_missing
goto target_found
:target_missing
    echo No Revert-RemoteAccessBlock script found next to this launcher.
    pause
    exit /b 1
:target_found
net session >nul 2>&1
if errorlevel 1 (
    echo Asking for administrator rights ...
    if "%~1"=="" (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs -Wait"
    )
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
