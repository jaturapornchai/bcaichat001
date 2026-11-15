@echo off
setlocal
set COUNT=%~1
if "%COUNT%"=="" set COUNT=2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\open_emulators.ps1" -Count %COUNT% %2 %3
if errorlevel 1 (
  echo.
  echo เกิดข้อผิดพลาดในการเปิด Android Emulator
  pause
)
