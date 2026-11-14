---
name: pc-rescue
description: Diagnose and repair a Windows PC that cannot stay up (blue screens such as CRITICAL_PROCESS_DIED, crashes even in Safe Mode, boot loops) by booting it from a SystemRescue USB stick built on a working Windows laptop and controlling it from the laptop over a direct Ethernet cable with key-only SSH. Covers the safety briefing and explicit consent, BitLocker and Secure Boot preparation, building and verifying the stick, connecting, read-only diagnosis (drive health, RAM, crash dumps, event logs), an optional file backup with size and time estimates, gated repairs and cleanup. Use it whenever the user has a second Windows PC that crashes, blue-screens or won't stay on long enough to fix in place and wants Claude to work on it from this machine, even if they only say "my other PC keeps crashing", "BSOD loop", "fix my PC over LAN", "rescue USB" or ask whether to turn off BitLocker or Secure Boot for it.
---

# PC Rescue

The faulty PC can't stay up in Windows, so it boots SystemRescue (Linux) from a USB stick instead. Claude runs on the user's working Windows laptop and controls the faulty PC through a direct Ethernet cable with SSH. That gives Claude a Linux root shell on the faulty PC, not Windows `cmd`. Windows' own repair tools (`chkdsk`, `sfc`, `DISM`, `reg load`) still run in the Windows recovery console, typed by the user.

Tooling in this repository (paths relative to the project root):

| Path | What it does |
|---|---|
| `scripts/write-usb.ps1` | Builds the stick from the ISO, with label checks and a disk-name guard |
| `usb/` | Files added to the stick: SSH key login, firewall off, fixed address `169.254.77.77` |
| `scripts/pc.ps1` | Runs one command on the rescue PC, or opens a shell |
| `scripts/pull.ps1` | Copies files from the rescue PC to the laptop (binary-safe) |
| `scripts/backup-plan.ps1` | Read-only: lists what a backup would copy, with sizes, file counts, biggest items and times |
| `keys/`, `downloads/`, `collected/` | SSH key, ISO, evidence copied from the PC. All gitignored, never commit them |

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

1. Download the latest SystemRescue ISO and its `.sha256` into `downloads/`. Say the file name, source and size, and get permission first. Check the hash.
2. Create the key if `keys/pcrescue_ed25519` doesn't exist: `ssh-keygen -t ed25519 -N '""' -C pcrescue-laptop -f keys\pcrescue_ed25519`. Restrict the private key file to the current user with `icacls`, or Windows OpenSSH refuses it.
3. Find the stick with `Get-Disk | Where-Object BusType -eq USB`. Show the user its name, size and what's on it before erasing. Use the exact `FriendlyName` as `-ExpectedName`.
4. Run `scripts/write-usb.ps1` in an elevated PowerShell. Tell the user a Windows admin prompt is coming and to click Yes. If the stick is already FAT32 with the ISO's label, `-ReuseVolume` rewrites it without elevation.
5. Verify before declaring it done. Compare `tar -tvf <iso>` names and sizes against the stick case-sensitively, and check that `autorun/autorun` and `sysrescue.d/500-pcrescue.yaml` have LF endings, no BOM and the real key.

The script unpacks with `tar.exe` on purpose. Copying from a Windows-mounted ISO gives the plain ISO 9660 names (`X86_64_EFI`, `100_DEFAULTS.YAML`), which breaks the boot loader and the default config. The FAT32 label must equal the ISO's `archisolabel` (e.g. `RESCUE1303`), or the boot stops at an emergency shell.

## Step 4: Boot and connect

Tell the user, one action at a time:

1. Plug the stick into the faulty PC, open the boot menu, and pick the stick's **UEFI** entry.
2. In the SystemRescue menu, the first entry starts by itself after 30 seconds. The menu also has a memory test entry for later if RAM is suspected.
3. Connect the Ethernet cable between the two machines.

On the laptop, wait about a minute for Windows to give the Ethernet port a `169.254.x.x` address. Then run `Test-Connection 169.254.77.77 -Count 2` and `.\scripts\pc.ps1 'uname -r; lsblk'`. If that fails, see the connection section of `references/preparation.md`.

Run every remote command as `.\scripts\pc.ps1 '<command>'`. Keep each command short and read-only until Step 7. Run anything long (memory or drive tests) with `nohup ... > /root/x.log 2>&1 &`, then check the log, because a dropped SSH session would otherwise kill it.

## Step 5: Read-only diagnosis

Follow `references/diagnosis.md`. In short:

1. Inventory the disks and find the Windows partition.
2. Check drive health (SMART or NVMe health, kernel I/O errors). If the drive is failing, stop broad scans and go to Step 6 at once to offer the backup, because every extra read may be one of its last.
3. Watch whether the rescue system itself stays up. Linux crashing or freezing as well points to hardware: RAM, CPU, power supply or heat.
4. Mount Windows read-only. If it's BitLocker-encrypted, the user unlocks it at the PC's own keyboard.
5. Pull evidence to the laptop's `collected/` folder: minidumps, event logs, CBS log. Analyze it on the laptop.

Then explain to the user in plain words what the evidence shows, the most likely cause, and how sure you are. Quote the specific lines or values.

## Step 6: Offer an optional file backup

Copying the user's files is optional. It can mean tens of GB and a long wait, and often it isn't needed: bad RAM or a broken driver doesn't put the files at risk. Offer it once the diagnosis is done and before the first repair that writes to the drive, and don't start it unasked.

Measure before asking, so the user decides with real numbers. With Windows mounted read-only at `/mnt/win`, run `.\scripts\backup-plan.ps1`. It's read-only and copies nothing. For every user's Desktop, Documents, Pictures, Videos, Music, Downloads and OneDrive it lists the size, file count, three biggest items and an estimated copy time. It also shows the total, free space at the destination, and what isn't included.

Useful options:
- `-Extra '<path>'` adds anything the user names, such as a game-saves folder or a browser profile under AppData.
- `-DriveMBps <n>` tightens the time estimate once the drive's read speed is known. Measure it with `dd if=<a large file> of=/dev/null bs=1M count=512`, but skip that on a failing drive.
- `-TsvPath collected\backup-plan.tsv` shows the list again without measuring again.

If the script can't run, measure with `du -sh` and estimate the time as GB × 1024 ÷ MB/s ÷ 60 minutes. Plan on about 80–100 MB/s for a 1 Gbps link.

Don't paste the raw output. Show it in chat as an easy-to-read table, one row per folder, with what's inside in plain words, then the total, where it goes and what's left out. For example:

| Folder | Size | Files | Time | Biggest items inside |
|---|---|---|---|---|
| David / Pictures | 21.0 GB | 14,200 | 6–8 min | Phone backup (20 GB), Wallpapers (0.8 GB) |
| David / Downloads | 13.5 GB | 750 | 4–5 min | Win11.iso (8 GB), game-setup.exe (4 GB) |
| David / Documents | 12.4 GB | 8,120 | 4–5 min | Projects (9.8 GB), Taxes (1.1 GB) |
| **Total** | **48.1 GB** | **23,410** | **14–18 min** | |

Goes to `C:\Projects\PcRescue\collected\backup` on this laptop (134 GB free). Not included: Windows, programs, and AppData (app settings, browser bookmarks and passwords).

Point out easy savings, such as installers or ISO files in Downloads that can be downloaded again. Then ask with AskUserQuestion, repeating the total and time, for example: "Back up these folders before repairs? 48.1 GB, about 14–18 minutes." Offer three options: back up all of them, pick folders, or skip. If they pick folders, show the new total and time before starting.

**If they agree:** copy one folder at a time with `.\scripts\pull.ps1 /mnt/win/Users/<user>/<folder> collected\backup\<user>`, or use `rsync` to an external drive attached to the PC. Start with the folders they care about most. Run long copies in the background and report progress from the destination's growing size.

**If the drive shows failure signs:** say clearly that this may be the last chance to read the files, and recommend the backup. The choice is still theirs.

**If they skip it:** say in the confirmation for any repair that could lose data that no backup exists.

## Step 7: Repairs, one confirmed change at a time

Pick from `references/repairs.md` by cause: failing drive, bad RAM, damaged system files, a bad driver or service, a stuck update. For every change, tell the user what will change, why the evidence supports it, how to undo it, what could go wrong, and whether their files are backed up. Then ask, and wait for an explicit yes. Back up any file before editing it, such as a registry hive. Mount read-write only for that one step.

## Step 8: Cleanup

- Boot Windows normally and watch whether it stays up.
- Turn Secure Boot back on. Resume BitLocker if it was suspended (`manage-bde -protectors -enable C:` in the recovery console, or `Resume-BitLocker -MountPoint C:` in Windows).
- Ask whether to delete `collected/`, which holds personal data, and whether to keep the stick and key for next time or wipe them.
- Summarize what was found, what changed, and what to watch for.

## Talking to the user

The user may not be technical, and they're the one walking between two machines. Give one physical step at a time, say what they should see on screen, and wait for them to report back. Keep secrets out of the conversation: never ask for passwords or recovery keys in chat, and if one is pasted anyway, don't repeat it.
