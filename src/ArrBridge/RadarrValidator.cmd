@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ReqestraArrBridge.ps1" -Source Radarr
exit /b %ERRORLEVEL%
