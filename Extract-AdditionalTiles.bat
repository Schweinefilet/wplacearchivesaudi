@echo off
REM Extract-AdditionalTiles.bat
REM Extracts X=1251-1253 tiles from existing tar.gz files for Taif coverage

cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Extract-AdditionalTiles.ps1"
pause
