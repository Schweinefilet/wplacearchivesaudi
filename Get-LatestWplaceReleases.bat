@echo off
setlocal
set PS1="E:\wplace-archive\Get-LatestWplaceReleases.ps1"
echo === wplace releases fetch %date% %time% ===
REM Optional: set GITHUB_TOKEN here or in System Environment
REM set GITHUB_TOKEN=ghp_xxx

powershell -NoProfile -ExecutionPolicy Bypass -File %PS1%
echo === done ===
pause
endlocal
