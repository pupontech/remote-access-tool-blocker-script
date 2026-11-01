@echo off
rem Compatibility launcher for the Windows App Control-only recovery tool.
rem Anti-scam confirmations use native Windows popups; no keyboard pause.
setlocal
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Revert-RemoteAccessBlock-WinOnly.v*.ps1" 2^>nul') do if not defined TARGET set "TARGET=%~dp0%%F"
if not defined TARGET goto target_missing
goto target_found
:target_missing
    echo No Revert-RemoteAccessBlock script found next to this launcher.
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
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%TARGET%" %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
