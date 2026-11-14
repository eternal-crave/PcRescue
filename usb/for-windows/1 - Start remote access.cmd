@echo off
rem PcRescue: lets the rescue laptop reach this PC's Windows over the direct Ethernet cable
rem (SSH, key login only, open only to the cable). Undo with "3 - Remove remote access (when finished)".
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-remote-access.ps1"
