@echo off
rem PcRescue: opens the status screen that shows what the laptop is doing on this PC.
rem It runs the "PcRescue status" task (with administrator rights, so it can read the drives'
rem health); if that isn't possible, it opens the screen directly.
schtasks /run /tn "PcRescue status" >nul 2>&1 && exit /b 0
if exist "%ProgramData%\PcRescue\status.ps1" (
  start "PcRescue status" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ProgramData%\PcRescue\status.ps1"
) else (
  echo The status screen isn't installed yet. Run "1 - Start remote access" first.
  pause
)
