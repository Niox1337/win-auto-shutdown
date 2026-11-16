@echo off
chcp 65001 >nul
if not exist "%~dp0AutoShutdown.ps1" (
  echo 找不到 AutoShutdown.ps1。请先把压缩包完整解压到一个文件夹，再双击里面的 Install.cmd。
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoShutdown.ps1" -Install
if errorlevel 1 pause
