@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0opencode-port.ps1" %*
set EC=%ERRORLEVEL%
if "%~1"=="" pause
exit /b %EC%
