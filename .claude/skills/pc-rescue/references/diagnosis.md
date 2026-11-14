# Read-only diagnosis

Everything here only reads. Run remote commands through `.\scripts\pc.ps1 '<command>'` and copy files back with `.\scripts\pull.ps1 <remote path> <local folder>`.

## 1. Inventory

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,SERIAL
blkid
```

Windows usually lives on the largest `ntfs` partition (or `BitLocker` in `FSTYPE`). Note the device names. NVMe is `/dev/nvme0n1pN`, SATA is `/dev/sdXN`.

## 2. Drive health

```sh
smartctl -x /dev/sda            # SATA (also works for NVMe: smartctl -x /dev/nvme0)
nvme smart-log /dev/nvme0       # NVMe
dmesg --level=err,warn | tail -60
```

Signs of a failing drive:
- SATA: non-zero `Reallocated_Sector_Ct`, `Current_Pending_Sector`, `Offline_Uncorrectable`, `Reported_Uncorrect`, or a SMART overall result of FAILED.
- NVMe: `critical_warning` not 0, `media_errors` above 0, `percentage_used` near or over 100, `available_spare` below its threshold.
- `dmesg` lines with `I/O error`, `blk_update_request`, `Buffer I/O error`, or `ata... failed command` / `nvme... timeout`.

A failing drive explains `CRITICAL_PROCESS_DIED` well. Windows can't read a core process's code from disk, and the process dies. If you see any of these signs, stop broad scans and go to file rescue.

Optional, only with the drive looking healthy: `smartctl -t short /dev/sda`, then read the result two minutes later with `smartctl -l selftest /dev/sda`.

## 3. RAM, CPU, heat

- The rescue system itself freezing or rebooting is strong evidence of hardware trouble.
- `sensors` shows temperatures. CPUs above about 95 °C under light load point to cooling.
- A quick RAM check from Linux: `nohup memtester 2G 1 > /root/memtester.log 2>&1 &`, then read the log. It tests only part of the RAM. The thorough test is the stick's boot-menu memory test (Memtest86+), which needs a reboot and the user watching the screen. One pass takes 30–90 minutes, and any error means bad RAM.
- `stress-ng --cpu 0 --timeout 120` plus `sensors` can show heat or power-supply problems. Use it only if the drive is healthy and the user agrees, because it loads the machine.

## 4. Mount Windows read-only

```sh
mkdir -p /mnt/win
ntfs-3g -o ro /dev/<windows partition> /mnt/win
ls -la /mnt/win/Windows/Minidump /mnt/win/Windows/LiveKernelReports /mnt/win/Windows/MEMORY.DMP 2>&1
```

Read-only mounting works even when Windows was hibernated or crashed. For BitLocker, see `preparation.md`: the user unlocks the drive at the PC's keyboard.

## 5. Pull evidence to the laptop (`collected/`)

```powershell
.\scripts\pull.ps1 /mnt/win/Windows/Minidump collected
.\scripts\pull.ps1 /mnt/win/Windows/System32/winevt/Logs/System.evtx collected
.\scripts\pull.ps1 /mnt/win/Windows/System32/winevt/Logs/Application.evtx collected
.\scripts\pull.ps1 /mnt/win/Windows/System32/winevt/Logs/Setup.evtx collected
.\scripts\pull.ps1 /mnt/win/Windows/Logs/CBS/CBS.log collected
```

Skip `MEMORY.DMP` unless there are no minidumps; it can be gigabytes. Check sizes first with `du -sh`.

## 6. Analyze on the laptop

**Event logs.** Windows reads `.evtx` files offline:

```powershell
$ids = 41,1001,6008,7,51,129,153,55,98,140,161,49,17,18,19,47
Get-WinEvent -Path .\collected\System.evtx -MaxEvents 4000 |
  Where-Object Id -in $ids |
  Select-Object TimeCreated, Id, ProviderName, @{n='Msg';e={($_.Message -split "`n")[0]}} |
  Format-Table -AutoSize -Wrap
```

| Event | Source | Meaning |
|---|---|---|
| 41 | Kernel-Power | Unexpected restart (the crash itself) |
| 1001 | BugCheck / WER | Blue screen code and parameters |
| 7, 51, 153 | disk | Bad block, paging error, retried I/O → drive or cable |
| 129 | storahci / stornvme | Controller reset → drive, cable or firmware |
| 55, 98, 140 | Ntfs | File system corruption or flush failure |
| 17, 18, 19, 47 | WHEA-Logger | Hardware errors (CPU, memory, PCIe) |
| 161, 49 | volmgr | Crash dump could not be written |

Look at the order of events in the minutes before each event 41.

**Minidumps.** Use Microsoft's WinDbg on the laptop. Ask before installing it (`winget install Microsoft.WinDbg`). Run `!analyze -v` on each dump. For stop code `0xEF`, note `PROCESS_NAME` (for example `svchost.exe`, `csrss.exe`, `wininit.exe`) and the exit status. `c0000006` (in-page error) or `c000009c`/`c0000185` point to the drive. An access violation in a third-party module points to that driver or software.

**Patterns.**
- Crashes in Safe Mode and in Linux → hardware.
- Crashes in Safe Mode only, and drive errors in logs or SMART → drive.
- Clean SMART, clean RAM test, and dumps blaming a system file → damaged Windows files. Repair in the recovery console.
- Crashes started right after an update or driver install (Setup.evtx, CBS.log) → roll that back.
