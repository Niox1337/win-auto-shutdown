@echo off
chcp 65001 >nul
set "SCRIPT=%LOCALAPPDATA%\AutoShutdown\AutoShutdown.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0AutoShutdown.ps1"
if not exist "%SCRIPT%" (
  echo 找不到 AutoShutdown.ps1。请在解压出来的文件夹里双击 Uninstall.cmd。
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Uninstall
if errorlevel 1 pause
