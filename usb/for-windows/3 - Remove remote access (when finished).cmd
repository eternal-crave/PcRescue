@echo off
rem PcRescue: removes the remote access that "1 - Start remote access" set up.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-remote-access.ps1" -Remove
