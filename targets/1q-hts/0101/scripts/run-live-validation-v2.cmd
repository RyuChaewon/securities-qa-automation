@echo off
setlocal
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-live-validation-v2.ps1"
set "EXIT_CODE=%errorlevel%"
echo.
echo 0101 live validation exit code: %EXIT_CODE%
pause
exit /b %EXIT_CODE%
