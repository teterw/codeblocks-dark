@echo off
REM Double-click entry point. Runs install.ps1 without touching the machine
REM execution policy: -ExecutionPolicy Bypass applies to this process only.
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" echo Install did not finish cleanly ^(exit code %RC%^).
pause
exit /b %RC%
