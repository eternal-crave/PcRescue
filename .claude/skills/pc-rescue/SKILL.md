---
name: pc-rescue
description: Diagnose and repair a Windows PC that can't be fixed in place (blue screens with any stop code, crashes even in Safe Mode, freezes, boot loops). It boots a SystemRescue USB stick built on a working Windows laptop, controlled from the laptop over a direct Ethernet cable with key-only SSH; when Windows stays up or the stick won't boot, the stick's for-windows tools turn on key-only SSH in Windows itself. Covers safety briefing and consent, BitLocker and Secure Boot preparation, building the stick, connecting, read-only diagnosis (drive health, RAM, crash dumps, event logs), an optional file backup with size and time, gated repairs and cleanup. Use it whenever the user has a second Windows PC that crashes, blue-screens or won't stay up long enough to fix and wants Claude to work on it from this machine, even if they only say "my other PC keeps crashing", "BSOD loop", "fix my PC over LAN", "rescue USB", "work on my other PC's Windows over the cable", or ask whether to turn off BitLocker or Secure Boot for it.
---

# PC Rescue

The faulty PC can't stay up in Windows, so it boots SystemRescue (Linux) from a USB stick instead. Claude runs on the user's working Windows laptop and controls the faulty PC through a direct Ethernet cable with SSH. That gives Claude a Linux root shell on the faulty PC, not Windows `cmd`. Windows' own repair tools (`chkdsk`, `sfc`, `DISM`, `reg load`) still run in the Windows recovery console, typed by the user.

When Windows stays up long enough to work in (after a fix, or from the start), or when the PC won't boot the stick, Claude can work inside Windows instead: the stick's `for-windows` folder turns on key-only SSH there, and `scripts/win.ps1` runs PowerShell on the PC. See "Windows route" after Step 4. The steps around it (consent, diagnosis, backup, repairs, cleanup) stay the same.

Tooling in this repository (paths relative to the project root):

| Path | What it does |
|---|---|
| `scripts/write-usb.ps1` | Builds the stick from the ISO, with label checks and a disk-name guard. `-WindowsToolsOnly` adds or refreshes only `for-windows\` on an existing stick, erasing nothing and without elevation |
| `usb/` | Files added to the stick: SSH key login, firewall off, fixed address `169.254.77.77` |
| `usb/pcrescue/` | Tools the stick installs at boot: the status screen on the PC's monitor, the command recorder behind it, and `pcrescue-readtest` (read-only whole-disk read test) |
| `usb/for-windows/` | Windows route, double-clicked on the faulty PC: `1 - Start remote access` (key-only SSH over the cable, the Windows status screen and its command recorder), `2 - Status screen`, `3 - Remove remote access (when finished)`, plus `read-test.ps1` (read-only whole-disk read test with SMART counters before and after) |
| `scripts/pc.ps1` | Runs a command on the rescue PC, shown under `-Label` on its status screen, or opens a shell |
| `scripts/win.ps1` | Windows route: runs a PowerShell command in the PC's Windows, shown under `-Label` on its status screen, or opens a shell |
| `scripts/install-status-screen.ps1` | Installs or refreshes the `usb/pcrescue` tools on the running PC, with no stick rewrite or reboot |
| `scripts/watch-kernel-log.ps1` | Streams the PC's kernel log (and with `-Voltages` its sensor readings) to `collected\pc-kernel.log`, so the last messages before a freeze survive |
| `scripts/pull.ps1` | Copies files from the rescue PC to the laptop (binary-safe) |
| `scripts/backup-plan.ps1` | Read-only: lists what a backup would copy, with sizes, file counts, biggest items and times |
| `cases/` | One log per rescued PC: hardware, evidence, what was tried, results, open items |
| `keys/`, `downloads/`, `collected/`, `cases/` | SSH key and the saved Windows target, ISO and OpenSSH installer, evidence copied from the PC, case logs. All gitignored, never commit them: the repository holds only the skill and its tools |

## Why the safety gates exist

Claude gets full root control over what may be the only copy of the user's files, on a drive that may be dying. A wrong write can't be undone, a dying drive can fail completely under heavy reads, and touching firmware settings on a BitLocker-encrypted PC can lock the user out of Windows until they find a 48-digit key. So the order is always: consent → preparation → read-only diagnosis → offer a file backup (optional) → one confirmed change at a time → cleanup. Skipping ahead saves minutes; the failure costs someone's photos.

## Step 1: Safety briefing and explicit consent

Before building a stick, asking the user to change BIOS settings, or touching the faulty PC, give this briefing in plain words (adapt it to what the user already knows):

- Use this only on a PC you own or are allowed to repair.
- While the rescue system runs, I have full administrator (root) control of that PC. I'll look before changing anything and ask before every change, but repairs to a disk can lose data, and a failing drive can stop working during heavy reads.
- The USB stick you give me will be completely erased.
- You'll turn off Secure Boot on that PC for a while. We turn it back on at the end.
- BitLocker: if that PC's drive is encrypted, you need its recovery key before changing BIOS settings, or Windows may refuse to start. You type the key yourself on that PC. Don't paste it into this chat; I won't type it.
- Before any repair, I'll offer to back up your files to this laptop. That's optional. I'll tell you how many GB it is and roughly how long it takes, and you decide.
- Don't run these steps or commands recklessly, or on other machines. They're meant for this one PC, step by step, with you watching.

Then ask with AskUserQuestion: "Do you understand these risks and agree to go ahead, with me asking before every change to that PC?", options "I understand, go ahead" and "Not yet". Proceed only on the first. An earlier explicit "I understand" in the same conversation counts; a general "fix my PC" does not.

## Step 2: Prepare the environment

Walk the user through what applies, one item at a time. Details and commands are in `references/preparation.md`.

**Laptop:** Windows with the built-in OpenSSH client, an Ethernet port (or USB adapter), about 3 GB free, on mains power. An Ethernet cable and a USB stick of 2 GB or more.

**Faulty PC:**

- **BitLocker.** Find out whether the drive is encrypted, and get the recovery key from account.microsoft.com/devices/recoverykey before any firmware change. If the recovery console works, *suspend* protection there with `manage-bde -protectors -disable X: -RebootCount 0`. `0` keeps it suspended through every crash and restart until it's resumed, and a PC like this restarts constantly. Check `manage-bde -status` first, because the recovery console often gives Windows a letter other than `C:`. Never fully decrypt a PC that keeps crashing: decryption rewrites the whole drive for hours, and a crash midway risks the data. Windows' "Turn off BitLocker" and the Settings "Device encryption" switch both decrypt. When users ask "should I disable BitLocker?", the answer is: have the key, suspend if you can, don't decrypt.
- **Secure Boot.** SystemRescue doesn't support it. The user sets it to Disabled in firmware setup and back on at the end. Recovery console → Troubleshoot → Advanced options → UEFI Firmware Settings opens setup without timing a key at power-on. Disable it rather than deleting the Secure Boot keys, so turning it back on stays simple.
  - Leave everything else in firmware alone: TPM, storage mode (AHCI/RAID/VMD), UEFI vs. legacy/CSM, and no "Load defaults". Changing those can stop Windows from starting or trigger BitLocker recovery by itself.
  - Note the boot-menu key (often F12, F11, F8 or Esc) and pick the stick there once, instead of changing the boot order.
- **Fast Startup and hibernation.** A PC that keeps crashing never shuts down cleanly, so Linux sees the Windows volume as unclean or hibernated and mounts it read-only. That's fine for diagnosis; writes need care (see `references/repairs.md`).

## Step 3: Build the stick

If a stick was built before, run the check in item 5 first and rebuild only if it fails. Writing takes about 10 minutes on a USB 2.0 stick, and logs in `downloads/` may describe an older build.

1. Download the latest SystemRescue ISO and its `.sha256` into `downloads/`. Say the file name, source and size, and get permission first. Check the hash. If the Windows route may be needed and the PC's Windows has no OpenSSH Server, also offer Microsoft's `OpenSSH-Win64-v<version>.msi` from github.com/PowerShell/Win32-OpenSSH/releases, with the same permission and a hash check against the release's published digest. `write-usb.ps1` copies the newest one to `for-windows\` and refuses it unless Microsoft signed it.
2. Create the key if `keys/pcrescue_ed25519` doesn't exist: `ssh-keygen -t ed25519 -N '""' -C pcrescue-laptop -f keys\pcrescue_ed25519`. Restrict the private key file to the current user with `icacls`, or Windows OpenSSH refuses it.
3. Find the stick with `Get-Disk | Where-Object BusType -eq USB`. Show the user its name, size and what's on it before erasing. Use the exact `FriendlyName` as `-ExpectedName`.
4. Run `scripts/write-usb.ps1` in an elevated PowerShell. Tell the user a Windows admin prompt is coming and to click Yes. If the stick is already FAT32 with the ISO's label, `-ReuseVolume` rewrites it without elevation.
5. Verify before declaring it done. Compare `tar -tvf <iso>` names and sizes against the stick case-sensitively, and check that `autorun/autorun` and `sysrescue.d/500-pcrescue.yaml` have LF endings, no BOM and the real key. The `for-windows` launchers and scripts need CRLF instead, and `for-windows/pcrescue.pub` the real key.

The script unpacks with `tar.exe` on purpose. Copying from a Windows-mounted ISO gives the plain ISO 9660 names (`X86_64_EFI`, `100_DEFAULTS.YAML`), which breaks the boot loader and the default config. The FAT32 label must equal the ISO's `archisolabel` (e.g. `RESCUE1303`), or the boot stops at an emergency shell.

## Step 4: Boot and connect

Tell the user, one action at a time:

1. Plug the stick into the faulty PC, open the boot menu, and pick the stick's **UEFI** entry.
2. In the SystemRescue menu, the first entry starts by itself after 30 seconds. The menu also has a memory test entry for later if RAM is suspected.
3. Connect the Ethernet cable between the two machines.

On the laptop, wait about a minute for Windows to give the Ethernet port a `169.254.x.x` address. Then run `Test-Connection 169.254.77.77 -Count 2` and `.\scripts\pc.ps1 -Label 'Saying hello' 'uname -r; lsblk'`. If that fails, see the connection section of `references/preparation.md`.

The PC's monitor switches to the PcRescue status screen (Alt+F8). It shows the current command, long tasks with a progress bar, Linux uptime, CPU temperature and load, memory, the cable, every mounted drive with read-only or READ-WRITE, copies to the laptop, and recent commands. A small heart pulses calmly beside the "This PC" panel next to a slow ECG line, and turns grey and flat when the cable is out. Users watch it out of the corner of an eye, so keep it calm: no flashing, no pace changes, and never let it push a panel off the screen.

Tell the user to expect the screen, and that Alt+F1 gives the command line. If it's missing, run `.\scripts\install-status-screen.ps1`. A stick written from an older copy of this repository needs this after every boot. To check what the screen shows, read the console text: `fold -w <cols> /dev/vcs8`.

Run every remote command as `.\scripts\pc.ps1 -Label '<what it does, in plain words>' '<command>'`. The label is what the person at the PC reads, so write "Checking the SSD for read errors", not the command. Multi-line here-strings (`@'...'@`) and quotes arrive intact. Keep commands read-only until Step 7.

An occasional `Connection timed out` while ping still answers means the link dropped a few packets. Retry once before troubleshooting.

Run anything long, such as read tests, memory tests or big copies, as its own service: `systemd-run --unit=<name> --collect <command>`. A dropped SSH session then doesn't stop it. Background work can report progress to the status screen by writing `label|percent|detail` to `/run/pcrescue/tasks/<name>` and deleting the file when done.

## Windows route: work inside Windows

Use it when Windows stays up long enough to sign in and work, or when the PC stops at power-on or doesn't list the stick. It needs the user signed in to an administrator account on the faulty PC, and the same cable. Linux stays the route for a PC that crashes within minutes: Windows' own problems then interrupt every command.

Setting it up changes the PC, so explain it and ask first. `1 - Start remote access` installs OpenSSH Server if it's missing, accepts only the PcRescue key for administrator accounts, opens port 22 only to the cable (`169.254.x.x`), starts the service with Windows, and adds the status screen with a sign-in task. While it's on, Claude has full administrator control of that Windows over the cable. `3 - Remove remote access (when finished)` undoes exactly what it changed.

1. Make sure the stick has `for-windows`. A stick written from an older copy of this repository needs `.\scripts\write-usb.ps1 -DiskNumber <n> -ExpectedName '<FriendlyName>' -PublicKeyPath .\keys\pcrescue_ed25519.pub -WindowsToolsOnly` on the laptop. It erases nothing.
2. The user plugs the stick into the running PC, opens its `for-windows` folder, double-clicks `1 - Start remote access` and clicks Yes at the admin prompt. The window shows the PC's cable address and login name; the user reads out the address.
3. On the laptop: `.\scripts\win.ps1 -Address <address> -Label 'Saying hello' 'Get-ComputerInfo -Property OsName, OsVersion'`. The address is saved for later calls, and the login name comes from the PC's SSH banner. If the connection fails, see the Windows route section of `references/preparation.md`.

Run every command as `.\scripts\win.ps1 -Label '<what it does, in plain words>' '<PowerShell>'`, the same way as `pc.ps1`. It runs elevated in Windows PowerShell 5.1 on the PC. The PC's monitor shows the Windows status screen (`2 - Status screen` reopens it). Keep its panels and the calm heart the same as on the Linux screen. Keep the launcher names numbered in the order the user runs them, so "Remove" never sorts above "Start".

What differs from Linux:
- Windows has every drive mounted read-write, and Windows itself keeps writing to them. Keep commands read-only until Step 7. Check whether Windows' own maintenance, such as the scheduled drive optimizer, works on a failing drive (`references/diagnosis.md`, "Inside Windows").
- Start long work, such as `read-test.ps1`, detached from SSH so a dropped connection doesn't stop it. Its header shows how.
- Copy files to the laptop with `scp` using the PcRescue key and `keys\known_hosts_win`. The PC's port may be 100 Mbps here too.

## Step 5: Read-only diagnosis

Follow `references/diagnosis.md`. In short:

1. Inventory the disks and find the Windows partition. Also mount the other NTFS partitions read-only and list their top folders. A data disk full of the user's files matters for Step 6, even when it isn't the cause.
2. Check every disk's health: SMART or NVMe health, the SMART error log and how old its entries are, kernel I/O errors. If a hard disk shows failure signs, stop broad scans of it and go to Step 6 at once to offer the backup, because every extra read may be one of its last.
3. Watch whether the rescue system itself stays up. Linux crashing or freezing as well points to hardware: RAM, CPU, power supply or heat. Once the PC has frozen even once, keep `scripts\watch-kernel-log.ps1 -Voltages` running in the background for the rest of the session. Ask the user for a photo of the PC's screen whenever it stops answering.
4. Mount Windows read-only. If it's BitLocker-encrypted, the user unlocks it at the PC's own keyboard.
5. Pull evidence to the laptop's `collected/` folder: minidumps, event logs (including `Microsoft-Windows-Partition%4Diagnostic.evtx`), CBS log. Analyze it on the laptop. Windows numbers disks differently from Linux: map an event's "Disk N" to a model and serial before blaming a disk.
6. If the logs point at the Windows disk (retried I/O or paging errors around the crashes) but its SMART looks clean, run the read test on it: `systemd-run --unit=pcrescue-readtest-sdX --collect /usr/local/bin/pcrescue-readtest /dev/sdX`. Many cheap SSDs report almost nothing in SMART, so PASSED proves little. The test only reads. Skip it on a hard disk with SMART failure signs.
   - If the disk drops off during the test, that is the finding. Stop, release its mount with `umount -l`, and don't hammer it again before the physical fix.

`references/diagnosis.md` explains how to tell link errors (cable, port, power) from worn-out media.

Then explain to the user in plain words what the evidence shows, the most likely cause, and how sure you are. Quote the specific lines or values.

## Step 6: Offer an optional file backup

Copying the user's files is optional. It can mean tens of GB and a long wait, and often it isn't needed: bad RAM or a broken driver doesn't put the files at risk. Offer it once the diagnosis is done and before the first repair that writes to the drive, and don't start it unasked.

Measure before asking, so the user decides with real numbers. With Windows mounted read-only at `/mnt/win`, run `.\scripts\backup-plan.ps1`. It's read-only and copies nothing. For every user's Desktop, Documents, Pictures, Videos, Music, Downloads and OneDrive it lists the size, file count, three biggest items and an estimated copy time. It also shows the total, free space at the destination, and what isn't included.

Useful options:
- `-Extra '<path>'` adds anything the user names, such as a game-saves folder or a browser profile under AppData.
- `-DriveMBps <n>` tightens the time estimate once the drive's read speed is known. Measure it with `dd if=<a large file> of=/dev/null bs=1M count=512`, but skip that on a failing drive.
- `-TsvPath collected\backup-plan.tsv` shows the list again without measuring again.

The script measures only the Windows user folders. Add personal folders on other disks with `-Extra`, for example `-Extra '/mnt/<partition>/<folder>'`, and copy first from a disk that shows failure signs.

If the script can't run, measure with `du -sh` and estimate the time as GB × 1024 ÷ MB/s ÷ 60 minutes. Plan on about 80–100 MB/s for a 1 Gbps link and 9–11 MB/s for 100 Mbps (about 35 GB an hour). Check the PC's own port with `ethtool <device>`: many older boards have a 100 Mbps network chip, so a slow link isn't necessarily a bad cable. For hundreds of GB, suggest an external USB drive plugged into the faulty PC instead. `rsync` there runs at the drives' speed, not the cable's.

Don't paste the raw output. Show it in chat as an easy-to-read table, one row per folder, with what's inside in plain words, then the total, where it goes and what's left out. For example:

| Folder | Size | Files | Time | Biggest items inside |
|---|---|---|---|---|
| Alex / Pictures | 21.0 GB | 14,200 | 6–8 min | Phone backup (20 GB), Wallpapers (0.8 GB) |
| Alex / Downloads | 13.5 GB | 750 | 4–5 min | Win11.iso (8 GB), game-setup.exe (4 GB) |
| Alex / Documents | 12.4 GB | 8,120 | 4–5 min | Projects (9.8 GB), Taxes (1.1 GB) |
| **Total** | **48.1 GB** | **23,410** | **14–18 min** | |

Goes to `C:\Projects\PcRescue\collected\backup` on this laptop (134 GB free). Not included: Windows, programs, and AppData (app settings, browser bookmarks and passwords).

Point out easy savings, such as installers or ISO files in Downloads that can be downloaded again. Then ask with AskUserQuestion, repeating the total and time, for example: "Back up these folders before repairs? 48.1 GB, about 14–18 minutes." Offer three options: back up all of them, pick folders, or skip. If they pick folders, show the new total and time before starting.

**If they agree:** copy one folder at a time with `.\scripts\pull.ps1 /mnt/win/Users/<user>/<folder> collected\backup\<user>`, or use `rsync` to an external drive attached to the PC. Start with the folders they care about most. Run long copies in the background and report progress from the destination's growing size.

**If the drive shows failure signs:** say clearly that this may be the last chance to read the files, and recommend the backup. The choice is still theirs.

**If the memory test showed errors:** copy nothing until the PC runs only on sticks that passed. Bad RAM can silently corrupt the copies.

**If they skip it:** say in the confirmation for any repair that could lose data that no backup exists.

## Step 7: Repairs, one confirmed change at a time

Pick from `references/repairs.md` by cause: a bad SATA connection (cable, port or power plug, fixed by hand with the PC off, then confirmed with the read test), a failing drive, bad RAM, damaged system files, a bad driver or service, a stuck update. Fix hardware causes before any software repair: `chkdsk` or `sfc` on a disk that keeps dropping off can do harm. For every change, tell the user what will change, why the evidence supports it, how to undo it, what could go wrong, and whether their files are backed up. Then ask, and wait for an explicit yes. Back up any file before editing it, such as a registry hive. Mount read-write only for that one step.

## Step 8: Cleanup

- Boot Windows normally and watch whether it stays up.
- Turn Secure Boot back on, if the user turned it off for the stick. Not when Windows boots in legacy/CSM mode (MBR disk with a System Reserved partition): there Secure Boot was off before the rescue started, and turning it on usually needs CSM off, which stops that Windows from starting.
- On the first Windows start after the crashes, Windows may check the disk ("Scanning and repairing drive"). Tell the user to let it finish. Once Windows stays up, it's worth repairing system files the crashes may have damaged: in an admin terminal `DISM /Online /Cleanup-Image /RestoreHealth`, then `sfc /scannow`. The user runs these in Windows; they replace damaged system files with good copies and leave personal files alone.
- Resume BitLocker if it was suspended (`manage-bde -protectors -enable C:` in the recovery console, or `Resume-BitLocker -MountPoint C:` in Windows).
- If the Windows route was used: the user double-clicks `3 - Remove remote access (when finished)`. If the laptop got a second link-local address for `-Bind`, remove it (admin: `Remove-NetIPAddress -IPAddress <address> -Confirm:$false`) and run `.\scripts\win.ps1 -Bind none`.
- Turn back on anything paused during the rescue, such as the drive optimizer's schedule, still leaving out a drive that's failing.
- Ask whether to delete `collected/`, which holds personal data, and whether to keep the stick and key (with `keys\win-target.txt` and `keys\known_hosts_win`) for next time or wipe them.
- Summarize what was found, what changed, and what to watch for.

## Case log and skill upkeep

Keep each PC's story in its own file, `cases/<yyyy-mm-dd>-<short-name>.md`, and update it as the work goes. The folder is gitignored: case logs stay on this machine and are never committed. Record the hardware, the evidence with its numbers, what was tried, the results and the open items. Leave out passwords, keys, serial numbers and the names of the user's personal files and folders. A new session on the same PC starts by reading that file.

This skill holds only rules that fit any PC. When a case teaches something new, add it here or in `references/` as a general rule, without that case's names, dates or numbers. A concrete scenario goes into `evals/` as a test case.

## Talking to the user

The user may not be technical, and they're the one walking between two machines. Give one physical step at a time, say what they should see on screen, and wait for them to report back.

When the user needs the PC off (to swap a cable, or to boot the memory test or Windows), stop any background stream first, then power off with a short delay: `systemd-run --on-active=10 systemctl poweroff`. Confirm from the laptop that pings stop and the Ethernet link goes to Disconnected. Don't reboot: after a one-time boot-menu choice, a reboot starts Windows by itself. When the PC stops answering unexpectedly, ask for a photo of its screen. Keep secrets out of the conversation: never ask for passwords or recovery keys in chat, and if one is pasted anyway, don't repeat it.
