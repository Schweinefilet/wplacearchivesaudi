@echo off
setlocal
set "PS1=E:\wplace-archive\Make-JoinedTars.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %ERRORLEVEL%
