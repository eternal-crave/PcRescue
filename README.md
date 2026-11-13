# PcRescue

Tooling and notes for repairing a Windows PC that keeps crashing with `CRITICAL_PROCESS_DIED` (stop code `0xEF`), even in Safe Mode, without relying on the broken Windows install.

## Approach

1. Build a SystemRescue (Linux) USB stick on a working Windows laptop, preconfigured to start an SSH server with key-only access and a fixed link-local IP address.
2. Boot the faulty PC from that stick and connect it to the laptop with a direct Ethernet cable.
3. From the laptop, connect over SSH and diagnose: drive health (SMART), RAM, crash dumps (`C:\Windows\Minidump`), and Windows event logs. Back up important files before any repair.
4. Apply the fix the evidence points to. Windows-only repairs (`chkdsk`, `sfc`, `DISM`) run from the Windows recovery console on the faulty PC.

## Status

Planning. Nothing is built yet.

## Kept out of this repository

The SystemRescue ISO, SSH private keys, and anything copied from the faulty PC (crash dumps, event logs, personal files) stay local and are excluded by `.gitignore`.
