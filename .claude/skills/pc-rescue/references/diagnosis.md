# Read-only diagnosis

Everything here only reads. Run remote commands through `.\scripts\pc.ps1 -Label '<plain words>' '<command>'` and copy files back with `.\scripts\pull.ps1 <remote path> <local folder>`.

## 1. Inventory

```sh
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,SERIAL
blkid
```

Windows usually lives on the largest `ntfs` partition (or `BitLocker` in `FSTYPE`). Note the device names. NVMe is `/dev/nvme0n1pN`, SATA is `/dev/sdXN`. With several disks, find the one holding `Windows/System32` after mounting. A 50 MB "System Reserved" partition next to it means Windows boots in legacy (CSM) mode, which is one more reason to leave that firmware setting alone.

Mount every other NTFS partition read-only too, and list what's on it:

```sh
for p in sda1 sdb1; do mkdir -p /mnt/$p; ntfs-3g -o ro /dev/$p /mnt/$p; echo "== $p"; ls /mnt/$p; done
```

Folders named after a person, project files, photos or videos on a second disk are personal data. Whether that disk is healthy decides how urgent the backup in SKILL.md Step 6 is, even when the crashes come from another disk.

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

Reading SMART well:
- **How recent?** `smartctl -l error` stamps each error with the disk's power-on hours. Compare with attribute 9 (`Power_On_Hours`). An error 13 hours ago is current; one 7,000 hours ago is history.
- **`UDMA_CRC_Error_Count`** counts transfers corrupted on the cable, not on the platters. A large number points to the SATA cable, connector or port. Error-log entries with `ICRC, ABRT` say the same.
- **`UNC` errors and `Current_Pending_Sector`** are unreadable sectors on the media itself.
- **`FAILING_NOW` on any attribute** (its normalized VALUE at or below the threshold) is a real failure, even with zero reallocated sectors. On some hard disks it's `Raw_Read_Error_Rate`.
- **A bad data cable** shows only as `UDMA_CRC_Error_Count`, `ICRC` entries in the error log, and kernel link messages (`BadCRC`, `10B8B`, a non-zero `SErr`). It can't fail `Raw_Read_Error_Rate` or a self-test, because both happen inside the drive. To tell old cable trouble from current: check whether the CRC count is still rising, and how old the `ICRC` entries are (error-log age = `Power_On_Hours` minus the hours on the entry).
- **Cheap SSDs** (often DRAM-less models) report a handful of attributes that never change. PASSED on those proves little; the read test below is the real check.

**The drive's short self-test** (`smartctl -t short /dev/sdX`, read with `smartctl -l selftest /dev/sdX` after 1–2 minutes) is light: the drive checks itself for about two minutes and moves no data over the cable. Run it on every hard disk, including a failing one. A failed self-test is the drive's own second verdict, which helps when a FAILED attribute alone doesn't convince the user.
- `Completed without error`: passed.
- `Completed: read failure` (with an LBA): unreadable sectors.
- `Completed: servo/seek failure` or `electrical failure`: mechanics or electronics.
- `Completed: handling damage??`: the drive suspects physical shock damage. `G-Sense_Error_Rate` counts the shocks its sensor recorded.

Don't follow a failed self-test with the extended self-test or a full read: they read the whole disk once, the same wear as copying the files off it. If the user wants the files, the copy is the better use of those reads, and it also shows which files, if any, can't be read.

### Read test (whole disk, read-only)

The stick installs `pcrescue-readtest`. It reads the whole disk once in 1 GiB steps with `dd iflag=direct`, writes nothing, shows progress on the PC's status screen, and logs `<GiB> <milliseconds> ok|ERROR` per step to `/root/readtest-<disk>.log`:

```sh
dmesg | wc -l > /root/readtest-sdX.dmesg-start      # to see only new kernel messages afterwards
systemd-run --unit=pcrescue-readtest-sdX --collect /usr/local/bin/pcrescue-readtest /dev/sdX
```

Use it on SSDs and on hard disks with clean SMART. Don't run it on a hard disk with failure signs: back up first. A healthy SATA SSD reads 1 GiB in 2–5 s (on a 3 Gb/s port about 4 s).

A hard disk is fastest at the start and slows smoothly toward the end, often to half the speed: the outer tracks hold more data per turn. That smooth rise in the log is normal. Find the partition that holds each failed sector (`/sys/block/sdX/sdXN/start` and `size`, in 512-byte sectors) and tell the user whether it's in their files or in data that can be replaced. The kernel's "auto reallocate failed" means the drive couldn't move the sector during the read. It stays pending until something writes to it, and only then gets replaced from the spare pool. Afterwards read the new kernel messages: `dmesg | tail -n +$(( $(cat /root/readtest-sdX.dmesg-start) + 1 )) | grep -E 'ata[0-9]|sd[a-z]' | head -n 30`.

Telling the cause apart from the kernel messages:

| Messages | Meaning |
|---|---|
| `interface fatal error`, `SError: { UnrecovData 10B8B BadCRC }`, `hard resetting link`, `ICRC` | The SATA link corrupts data: cable, connector, port, or power to the drive. The stored data is usually intact. |
| `Logical unit not ready, hard reset required`, then `detaching`, `rejecting I/O to offline device` | The drive stopped answering and Linux dropped it. It follows link errors, or comes from a failing controller. |
| `UNC`, `Medium Error`, `Unrecovered read error` at specific sectors, with `SErr 0x0` and a steady CRC count | Unreadable media: the drive itself is failing. |
| Single steps much slower than their neighbours, with no errors (not the smooth slowdown toward a hard disk's end) | Weak areas or an overheating or throttling drive. Note which GiB. |

If the disk drops off, stop. Release its mount with `umount -l /mnt/<dir>`. It comes back after a power cycle. Don't rescan or retest it before the physical fix in `repairs.md`.

## 3. RAM, CPU, heat

- The rescue system itself freezing or rebooting is strong evidence of hardware trouble. Signs from the laptop: the PC suddenly stops answering pings while the laptop's cable link stays up. On the PC's monitor, the SystemRescue kernel shows a crash as a screen of kernel log lines, usually on a blue background. The crash reason may be cut off at the bottom, so ask the user for a photo anyway.
- After such a crash, have the user hold the power button to turn it off and boot the stick again. Check for a saved crash report: `ls /sys/fs/pstore`. On SystemRescue it's usually empty, because the `efi_pstore` backend is off by default (`cat /sys/module/pstore/parameters/backend` shows `(null)`). Don't force it on: it writes crash logs into the motherboard's firmware memory, and some old boards fail badly when that fills.
- Instead, catch the next crash live. Start `.\scripts\watch-kernel-log.ps1 -Voltages` as a background job. It streams the kernel log, plus voltages and temperatures every 5 s, into `collected\pc-kernel.log` and reconnects after drops. After a crash, read the end of that file. Messages printed during the crash itself can't get out over SSH, but warnings before it (machine-check errors, oopses, link resets, a falling voltage) do.
- Voltages: `modprobe nct6775` (or `it87`) and `sensors` show the motherboard's readings. Only some rails are labelled (`+3.3V`, `3VSB`, `AVCC`). The 12 V and 5 V rails sit on inputs like `in1`–`in14` with board-specific scaling, so watch them for changes under load rather than reading them as volts. On Intel CPUs with a built-in voltage regulator (4th and 5th generation Core), `Vcore` around 1.8 V is normal: it's the input voltage, not the core voltage. `Vbat` under about 2.8 V means a flat CMOS battery. Temperatures far over 100 °C on `SYSTIN` or `AUXTIN` are unconnected inputs, not heat.
- Linux crashing as well as Windows usually means the power supply, RAM or motherboard. A weak or failing power supply also explains SATA drives that reset or drop off (`Logical unit not ready, hard reset required`), because their power dips. Test RAM with the boot menu's memory test. For the power supply, check whether the crashes follow load (big read tests, the graphics card), and try a known-good unit if one is available.
- `sensors` shows temperatures. CPUs above about 95 °C under light load point to cooling.
- A quick RAM check from Linux: `nohup memtester 2G 1 > /root/memtester.log 2>&1 &`, then read the log. It tests only part of the RAM.
- The thorough test is the stick's own boot-menu entry **"Memtest86+ memory tester for UEFI"**. The laptop can't see it, so the user watches and reports. To hand over:
  1. Stop `watch-kernel-log.ps1` first. Its open SSH session holds up the shutdown.
  2. Power the PC off (`systemd-run --on-active=10 systemctl poweroff`); don't reboot it. After a one-time boot-menu choice, a reboot starts Windows by itself.
  3. The user powers on, picks the stick's UEFI entry in the boot menu, then the Memtest86+ line within the menu's 30 seconds.
  - **Reading the result:** Memtest86+ shows a `Pass` counter and an `Errors` count, and lists failing addresses in red or orange. `Status: Failed!` only means errors were found. The test keeps going, so users often think it has stopped; the spinner beside the status and the `Time` clock show it's still running. Let it finish at least one full pass, two if time allows. A pass takes very roughly half an hour per 8 GB, longer on older or slower machines. Memtest86+ never stops by itself. After the first full pass with no errors it shows a big green `PASS` banner (any key hides it) and starts the next pass, which users often find confusing. The `Pass:` counter shows finished passes and `Pass NN%` shows progress in the current one. Zero errors after a full pass makes RAM unlikely. Any error is a memory fault, and hundreds of errors settle it without waiting for the pass to end. Ask for a photo of the screen.
    - Memtest86+ looks for USB keyboards only when it starts, so a keyboard plugged in during the test isn't seen: the banner stays and Esc does nothing. Have the user plug the keyboard in before powering on. On a few boards the USB keyboard doesn't work in Memtest86+ under UEFI at all. The test doesn't need the keyboard, and holding the power button stops it. Don't change firmware settings (USB legacy support, XHCI hand-off) just for that.
    - **Running or frozen:** the `Time` clock ticks every second and the small mark right of `Status` spins. If both stay still for over a minute, Memtest has frozen. A finished pass still counts. A freeze is no error count, but note it: it points to instability elsewhere (CPU, board, power supply). If it also happens with the other stick, check that part next.
  - **What the error list says:**
    - Failing addresses packed into a narrow range (for example all within a few MB of each other) point to one bad spot on one stick. Errors spread across the whole memory point more to the memory settings, a slot, the CPU's memory controller or the power supply.
    - The `IMC:` line shows the memory speed and timings. Values matching the speed on the stick's label and the standard timings for its type rule out an overclock or XMP profile. Faster or tighter values mean turning XMP off, or setting the memory to Auto, comes first. That's a firmware change, so it needs the user's yes, and not via "Load defaults" (see SKILL.md Step 2).
    - The address doesn't tell which stick is bad, because dual-channel boards spread neighbouring addresses over both sticks.
  - **A memory fault doesn't cause SATA link errors** (BadCRC, 10B8B, interface fatal error). The link checks its data on the wire, after memory. So a PC can have both a bad SATA cable and bad RAM, and fixing one doesn't clear the other. Bad RAM does explain crashes of the rescue system itself.
  - **Finding the bad stick:**
    1. The user stops the test by holding the power button until the PC is off. Memtest writes nothing to the disks, so that's safe. Not Esc: it restarts the PC, and the restart boots Windows on the bad RAM.
    2. With the mains cable out, they leave one stick in the first slot (printed `DIMM1`, `A1` or `CH A` on the board) and run the memory test until the first error or the green `PASS` banner after one full pass. The "Memory SPD Information" list confirms which slot is in use (numbered from `Slot 0`).
    3. Then they test the other stick alone in the same slot.
  - **Reading the per-stick results:**
    - Only one stick fails: that stick is bad. Run the PC on the good one until it's replaced.
    - Both fail in the same slot: test one of them in the other slot. If it passes there, the first slot is at fault. If it also fails there, suspect the CPU's memory controller, the board or the power supply.
    - Neither fails alone: taking the sticks out and back in may itself have fixed a bad contact. Put both back, firmly, until both clips snap shut by themselves, then test them together. If the errors came within minutes before, the first 10–15 minutes say a lot, but let one full pass finish.
      - If errors return, test one stick alone in the second slot. Failing there means that slot is bad. Passing means the sticks only fail together, which points to the board, the memory controller or the power supply.
      - Either way, run the PC meanwhile on one stick in the slot that passed.
      - If they pass together now, it was most likely a bad contact. Contact faults can come back, so confirm on the next boots: run `watch-kernel-log.ps1` and watch that the rescue system stays up. If anything crashes again, reseat and test once more, or run the test overnight.
  - **Bad RAM damages whatever passes through it.** Don't copy files, run `chkdsk`/`sfc` or boot Windows until the PC runs on memory that passed. Copied files could be silently corrupted, and repairs could write corrupted data to the disk.
- If a Linux crash happens with the graphics driver loading or busy (`amdgpu`, `nouveau`, `i915` lines at the end of the log), boot the menu's "basic display drivers (nomodeset)" entry. If the crashes stop there, the graphics card or its driver is the cause.
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
.\scripts\pull.ps1 '/mnt/win/Windows/System32/winevt/Logs/Microsoft-Windows-Partition%4Diagnostic.evtx' collected
.\scripts\pull.ps1 /mnt/win/Windows/Logs/CBS/CBS.log collected
```

The PC's status screen names the file being copied while `pull.ps1` runs. The PC's own port may be 100 Mbps, about 10 MB/s, so a 20 MB event log takes a few seconds.

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

Look at the order of events in the minutes before each event 41. Counting per day lines disk trouble up with crashes:

```powershell
Get-WinEvent -FilterHashtable @{ Path = (Resolve-Path .\collected\System.evtx).Path; Id = 51, 153, 41, 1001 } |
  Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd') } | Sort-Object Name -Descending | Select-Object -First 15 |
  ForEach-Object { $g = $_.Group; '{0}  51:{1} 153:{2} 41:{3} 1001:{4}' -f $_.Name, @($g | ? Id -eq 51).Count, @($g | ? Id -eq 153).Count, @($g | ? Id -eq 41).Count, @($g | ? Id -eq 1001).Count }
```

**Which disk is "Disk N"?** Disk events name Windows' disk number (for example `Disk 1`, `\Device\Harddisk1\DR1`), which doesn't follow Linux's `sda`/`sdb` order. The Partition/Diagnostic log records every disk's number, model and serial at each boot:

```powershell
Get-WinEvent -Path '.\collected\Microsoft-Windows-Partition%4Diagnostic.evtx' -MaxEvents 30 | Where-Object Id -eq 1006 |
  ForEach-Object { $d = @{}; ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
    '{0:MM-dd HH:mm}  Disk {1}  {2}  {3}' -f $_.TimeCreated, $d.DiskNumber, $d.Model, $d.SerialNumber }
```

Match the model and serial with `smartctl -i` on the PC.

**Minidumps.** Use Microsoft's WinDbg on the laptop. Check first whether it's installed (`Get-AppxPackage Microsoft.WinDbg`), and ask before installing it (`winget install Microsoft.WinDbg`). It downloads Microsoft's public symbols, tens of MB from msdl.microsoft.com, so say so when asking. Run `!analyze -v` on each dump. For stop code `0xEF`, note `PROCESS_NAME` (for example `svchost.exe`, `csrss.exe`, `wininit.exe`) and the exit status. `c0000006` (in-page error) or `c000009c`/`c0000185` point to the drive. An access violation in a third-party module points to that driver or software.

**Patterns.**
- Retried I/O (153) or paging errors (51) on the Windows disk around the crash times, plus `0xEF` → the system disk or its SATA connection. Confirm with the read test and its kernel messages before choosing between a new cable and a new disk.
- Crashes in Safe Mode and in Linux → hardware.
- Crashes in Safe Mode only, and drive errors in logs or SMART → drive.
- Clean SMART, clean RAM test, and dumps blaming a system file → damaged Windows files. Repair in the recovery console.
- Crashes started right after an update or driver install (Setup.evtx, CBS.log) → roll that back.

## 7. Inside Windows (Windows route)

With the Windows route on, the same checks run in Windows through `win.ps1`, which runs elevated. Everything below only reads.

```powershell
Get-PhysicalDisk | Sort-Object DeviceId | Format-Table DeviceId, FriendlyName, SerialNumber, MediaType, BusType, HealthStatus
Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus | Format-Table InstanceName, PredictFailure, Reason
Get-PhysicalDisk | Get-StorageReliabilityCounter | Format-Table DeviceId, ReadErrorsUncorrected, ReadErrorsTotal, Temperature, PowerOnHours, Wear
Get-Volume | Format-Table DriveLetter, FileSystemLabel, FileSystem, HealthStatus, SizeRemaining, Size
```

- **Two health verdicts.** `HealthStatus` is Windows' own view and can say Healthy while the drive's SMART predicts failure. `PredictFailure = True` is the drive's own verdict: treat it like SMART FAILED in Linux. `InstanceName` contains the model, which matches `FriendlyName`.
- **Event logs are live.** Query them in place with the event IDs from section 6, for example `Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7, 51, 153, 129, 41, 1001 } -MaxEvents 200`. For events from the current boot, "Disk N" is `Get-Disk`'s `Number` N.
- **Windows' own maintenance.** The scheduled drive optimizer (task `\Microsoft\Windows\Defrag\ScheduledDefrag`) optimizes every drive by default, a failing hard disk included, and defragmenting reads and rewrites much of it. Check its recent runs and state:

  ```powershell
  Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag' } -MaxEvents 20 | Format-Table TimeCreated, Message -Wrap
  Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' | Format-Table TaskName, State
  ```

  If it touches a failing drive, recommend that the user leaves that drive out in "Defragment and Optimize Drives", or turns the schedule off, until the files are safe. That's the user's change. Note it for cleanup.
- **Read test.** `read-test.ps1` is the Windows counterpart of `pcrescue-readtest`: raw reads in 1 MiB steps, never a write, slow steps (1 s or more) and unreadable spots logged, SMART counters (reallocated, pending, uncorrectable, CRC) before and after. The same rules apply: SSDs and clean hard disks; a hard disk with failure signs only after its files are safe and the user asks. `1 - Start remote access` doesn't install it, so copy it from the stick first, then start it detached from SSH (`<N>` is `Get-Disk`'s `Number`):

  ```powershell
  $s = (Get-Volume | Where-Object FileSystemLabel -like 'RESCUE*').DriveLetter
  Copy-Item "${s}:\for-windows\read-test.ps1" C:\ProgramData\PcRescue\ -Force
  Invoke-CimMethod Win32_Process -MethodName Create -Arguments @{ CommandLine =
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PcRescue\read-test.ps1 -Disk <N>' }
  ```

  Progress shows on the PC's status screen; the log is `C:\ProgramData\PcRescue\read-test-disk<N>.log`. A rising CRC count during the test means the cable or port still corrupts transfers.
- **Copying to the laptop.** Use `scp` with the PcRescue key and the Windows host keys, with forward slashes in the PC's paths (add `-o BindAddress=<address>` when `-Bind` is in use):

  ```powershell
  scp -i keys\pcrescue_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=keys\known_hosts_win `
    "<user>@<address>:C:/ProgramData/PcRescue/read-test-disk<N>.log" collected\
  ```

  `3 - Remove remote access` deletes `C:\ProgramData\PcRescue`, so copy any log you want to keep first.
