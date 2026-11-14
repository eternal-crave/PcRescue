# Repairs

Every repair writes to the faulty PC. Before each one, tell the user what changes, the evidence behind it, how to undo it, and the risk. Then wait for an explicit yes. Offer the optional file backup (SKILL.md Step 6) before the first repair. If the user skipped it, say in each risky repair's confirmation that no backup exists.

## Bad SATA connection (cable, port, power)

Evidence: during the read test the kernel logs `interface fatal error`, `SError: { UnrecovData 10B8B BadCRC }` and `hard resetting link`, and the disk may drop off (`detaching`). Windows logs retried I/O (event 153) or controller resets (129) for that disk. The drive's SMART media counters are clean. The data on the disk is usually intact: the corruption happens on the way, and the drive rejects or retries it.

This repair is by hand and writes nothing, but it means opening the PC, so explain it and ask like any other change. The user does it with the PC shut down and the power cable unplugged, one change at a time:

1. Replace the disk's SATA data cable with a new or known-good one, ideally with latches. Swapping it with another disk's cable also works as a test.
2. Plug it into a different SATA port on the motherboard. Prefer the 6 Gb/s ports; the board or its manual labels them (often SATA6G_1/2 or the first two ports).
3. Use a different power plug from the power supply. Avoid splitters and Molex-to-SATA adapters.
4. Boot the stick again and repeat the read test on that disk. A clean pass with normal speed on every GiB means the connection was the cause. Then boot Windows and watch it.

If the errors stay with a new cable, another port and another power plug, the disk's own interface or controller is failing: treat it as a failing drive below. Also check the other disks' `UDMA_CRC_Error_Count`. A high count there means their cables deserve the same treatment.

## Failing drive

No software repair makes a dying drive safe. Recommend replacing it.

1. Recommend the file backup from SKILL.md Step 6, with its size and time estimate, if it hasn't been done. It stays the user's choice. With a yes, copy the most important folders first: `rsync -a --info=progress2 /mnt/win/Users/<name>/Documents/ <destination>` to an external drive attached to the faulty PC, or `scripts/pull.ps1` to the laptop.
2. If there's space for a full image, `ddrescue` reads the healthy areas first and keeps a map file so it can resume: `ddrescue -n /dev/<disk> /path/disk.img /path/disk.map`.
3. After a new drive is installed: reinstall Windows (simplest), or clone the image to the new drive if the user wants the old system.

Don't run `chkdsk /r`, `fsck` or full surface scans on a failing drive. They stress it and can make it fail completely.

## Bad RAM

The memory test reports errors, or the rescue system freezes too. The user reseats the RAM sticks with the power cable unplugged, then tests one stick at a time with the boot-menu memory test. Replace the bad stick. No software fix exists.

## Damaged Windows system files

Run in the Windows recovery console, typed by the user. First find the Windows drive letter there, often `D:` (`dir C:\Windows`, `dir D:\Windows`). Replace `C:` below with that letter.

```bat
chkdsk C: /f
sfc /scannow /offbootdir=C:\ /offwindir=C:\Windows
DISM /Image:C:\ /Cleanup-Image /RestoreHealth /Source:wim:E:\sources\install.wim:1 /LimitAccess
```

`DISM` offline needs a source. That's `install.wim` (or `install.esd` with `esd:`) from a Windows ISO matching the installed version and edition, on a USB stick (`E:` here). Run `chkdsk /f` only when the drive's health is good.

## Bad driver or service

Find the module from the minidump or event logs. Disable it in the offline registry by setting its `Start` value to `4` (disabled). Note the old value for undo first. In the recovery console, typed by the user:

```bat
reg load HKLM\OFFSYS C:\Windows\System32\config\SYSTEM
reg query HKLM\OFFSYS\ControlSet001\Services\<driver> /v Start
reg add HKLM\OFFSYS\ControlSet001\Services\<driver> /v Start /t REG_DWORD /d 4 /f
reg unload HKLM\OFFSYS
```

Back up the hive first. From SystemRescue: `cp /mnt/win/Windows/System32/config/SYSTEM /root/SYSTEM.bak`, then pull it to the laptop. Never disable a boot-critical Microsoft driver (for example `disk`, `volmgr`, `storahci`, `stornvme`, `Ntfs`): Windows won't start without it.

From SystemRescue the same edit is possible with `chntpw -e` (interactive) or `reged -I` (imports a `.reg` file). The recovery console's `reg` is the safer tool for Windows' own registry format.

## Stuck or bad update

- Recovery console → Troubleshoot → Advanced options → Uninstall Updates: remove the latest quality update first, then the latest feature update.
- Pending actions that crash every start: `DISM /Image:C:\ /Cleanup-Image /RevertPendingActions` in the recovery console.
- System Restore (same Advanced options menu), if restore points exist.

## Writing to NTFS from SystemRescue

Read-write mounts of a crashed or hibernated Windows volume are refused by design. `ntfs-3g -o remove_hiberfile` forces it but discards the saved Windows session. That's usually acceptable after a crash, but explain it and ask first. Mount read-write only for the one confirmed change, then unmount: `umount /mnt/win`.

## Last resort

If repairs fail and the hardware is healthy, reinstall Windows after the files are rescued. Recovery console → Reset this PC keeps personal files but removes apps. A clean install from a Windows USB stick is the most reliable fix.
