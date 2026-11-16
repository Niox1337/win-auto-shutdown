@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\AutoShutdown\AutoShutdown.ps1" -Uninstall || powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoShutdown.ps1" -Uninstall
