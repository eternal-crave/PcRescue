# PcRescue

A Claude Code skill and toolkit for rescuing a Windows PC that can't be fixed in place: it blue-screens with any stop code, crashes even in Safe Mode, freezes, boot-loops or won't stay up long enough to work on. Claude works from a second, working Windows computer connected to the faulty PC by a direct Ethernet cable, over key-only SSH. It checks the drives (SMART, link errors, whole-disk read tests), RAM, crash dumps and event logs, offers to back up personal files over the cable, and makes repairs one confirmed step at a time.

A [Skillforge](https://github.com/eternal-crave/skillforge) shard, kept in its own repo because it ships with its rescue-USB tools and scripts.

## Two ways to work on the PC

- **Without loading Windows.** When Windows won't stay up, the faulty PC boots a Linux rescue system from a USB stick instead, so the broken Windows install never runs. Claude gets a root shell on the PC and reads the Windows drive from outside. The Linux on the stick is [SystemRescue](https://www.system-rescue.org/), an open-source rescue system built on Arch Linux (see [Credits](#credits)).
- **Inside Windows.** When Windows stays up long enough to work in, the same stick's `for-windows` folder turns on SSH in Windows itself. Claude then works in the PC's own PowerShell over the same cable, with a matching status screen on the PC's monitor.

> [!WARNING]
> **BitLocker users: get your recovery key before you change anything.** Booting the Linux stick requires turning off Secure Boot, and after that change Windows asks for the 48-digit BitLocker recovery key at its next start. SystemRescue also needs that key to read an encrypted drive. Many Windows 11 PCs turn on "Device encryption" (BitLocker) without asking, so check even if you never set it up: [account.microsoft.com/devices/recoverykey](https://account.microsoft.com/devices/recoverykey) lists the keys saved to your Microsoft account. Without the key you can be locked out of Windows and your files. If Windows stays up for a minute, *suspending* BitLocker avoids the prompt; don't *turn it off*, which decrypts the whole drive for hours. Type the key yourself on the PC and never paste it into a chat.

## How it works

- `usb/` holds files added to the stick on top of the SystemRescue ISO:
  - `sysrescue.d/500-pcrescue.yaml` turns off the SystemRescue firewall, authorizes the PcRescue SSH key and skips the keypress pause after startup scripts.
  - `autorun/autorun` runs once at boot. It authorizes the key again (in case the YAML option is ignored), allows key-only root login, gives every wired port the fixed address `169.254.77.77/16`, and installs the tools in `pcrescue/`.
  - `pcrescue/status.sh` is the status screen on the faulty PC's own monitor (Alt+F8). It lists the command running now, long tasks with a progress bar, Linux uptime, CPU temperature and load, memory, the cable, every mounted drive with read-only or READ-WRITE, files being copied over the cable, and recent commands. A small pixel heart pulses calmly beside the "This PC" panel next to a slow ECG line, and goes grey and flat when the cable is out.
  - `pcrescue/job.sh` records each command from `pc.ps1` for that screen. `pcrescue/readtest.sh` reads a whole disk once, read-only, and logs slow or failing areas.
  - `for-windows/` is for working inside Windows, once it stays up. The user double-clicks its launchers on the faulty PC's Windows:
    - `1 - Start remote access` (`setup-remote-access.ps1`) turns on key-only SSH for the PcRescue key. It uses Windows' OpenSSH Server, or installs it from the `OpenSSH-Win64-*.msi` copied next to it. Port 22 opens only to the cable (`169.254.x.x`), the service starts with Windows so access survives crashes and restarts, and the PC's cable address is shown. It also installs a Windows status screen into `C:\ProgramData\PcRescue` that opens at every sign-in.
    - `2 - Status screen` reopens that screen. It mirrors the SystemRescue one and adds how long Windows has stayed up and each drive's SMART verdict.
    - `3 - Remove remote access (when finished)` undoes exactly what step 1 changed, as recorded in `state.json`.
    - `job.ps1` records each command from `win.ps1` for the screen. `read-test.ps1` reads a whole disk once, read-only, and compares the drive's SMART counters before and after.
- Files that run on SystemRescue keep LF line endings; the Windows tools in `for-windows/` get CRLF. `.gitattributes` and `write-usb.ps1` both enforce this.
- With no router on the cable, Windows gives the working computer's Ethernet port a `169.254.x.x` address by itself, so both ends share a network without changing any network settings.
- SystemRescue boots only from a FAT32 volume whose label matches the ISO's label (for example `RESCUE1303`). `scripts/write-usb.ps1` reads the label from the ISO and checks it against the ISO's boot config.

## Usage

1. Download the SystemRescue ISO and its `.sha256` file from [system-rescue.org](https://www.system-rescue.org/) into `downloads/`, then check the hash. Optionally add Microsoft's Win32-OpenSSH installer (`OpenSSH-Win64-*.msi`) for PCs whose Windows has no OpenSSH Server; `write-usb.ps1` copies it to the stick after checking that Microsoft signed it.
2. Create the SSH key (kept in `keys/`, ignored by Git):

   ```powershell
   ssh-keygen -t ed25519 -N '""' -C pcrescue -f keys\pcrescue_ed25519
   ```

3. Write the stick from an elevated PowerShell. This erases the whole stick:

   ```powershell
   .\scripts\write-usb.ps1 -DiskNumber <n> -ExpectedName '<FriendlyName from Get-Disk>' `
     -IsoPath .\downloads\systemrescue-13.03-amd64.iso -PublicKeyPath .\keys\pcrescue_ed25519.pub
   ```

4. On the faulty PC: if its drive may use BitLocker, have the recovery key ready first (see the warning above). Turn off Secure Boot (SystemRescue does not support it), boot the stick's UEFI entry, and connect it to the working computer with the Ethernet cable.
5. From this repository's folder on the working computer:

   ```powershell
   .\scripts\pc.ps1 -Label 'Listing the disks' 'lsblk'      # run a command; the label shows on the PC's screen
   .\scripts\pc.ps1                                          # open a shell
   .\scripts\pull.ps1 /mnt/win/Windows/Minidump collected    # copy files back (binary-safe)
   .\scripts\backup-plan.ps1                                 # what a backup would copy: sizes, files, time (read-only)
   .\scripts\install-status-screen.ps1                       # refresh the PC-side tools without rewriting the stick
   .\scripts\watch-kernel-log.ps1 -Voltages                  # stream kernel log + sensors to collected\ (catches freezes)
   ```

   `pc.ps1` sends commands base64-encoded, so quotes and multi-line here-strings survive Windows PowerShell 5. For long jobs use `systemd-run` on the PC, for example `systemd-run --unit=pcrescue-readtest-sdX --collect /usr/local/bin/pcrescue-readtest /dev/sdX`, so a dropped connection doesn't stop them.

6. Once Windows stays up, continue in Windows over the same cable. A stick written in step 3 already has the `for-windows` folder. To add or refresh it on an existing stick without erasing anything (no elevation needed):

   ```powershell
   .\scripts\write-usb.ps1 -DiskNumber <n> -ExpectedName '<FriendlyName from Get-Disk>' `
     -PublicKeyPath .\keys\pcrescue_ed25519.pub -WindowsToolsOnly
   ```

   On the faulty PC, open the stick's `for-windows` folder and double-click `1 - Start remote access`. It shows the PC's cable address. Then, from this repository's folder:

   ```powershell
   .\scripts\win.ps1 -Address 169.254.x.x -Label 'Checking the disks' 'Get-PhysicalDisk'   # the first call saves the address
   .\scripts\win.ps1 -Label 'Reading the Windows version' 'Get-ComputerInfo -Property OsName, OsVersion'
   .\scripts\win.ps1                                                                      # open a shell
   ```

   `win.ps1` reads the login name from the PC's SSH banner and records the PC's host key in `keys\known_hosts_win`. If the working computer shares its internet over the cable, the PC gets a `192.168.137.x` address that its firewall rule doesn't cover; `Get-Help .\scripts\win.ps1` explains the `-Bind` workaround. Start `read-test.ps1` detached from SSH, as its header shows, so a dropped connection doesn't stop it.

7. When finished: if the Windows tools were used, double-click `3 - Remove remote access (when finished)` on the PC. Turn Secure Boot back on. On a BitLocker drive that wasn't suspended, Windows asks for the recovery key once more after that change.

## Claude skill

`.claude/skills/pc-rescue/` teaches Claude Code the whole workflow when it runs in this folder. It covers the safety briefing and explicit consent, BitLocker and Secure Boot preparation, building the stick, connecting, read-only diagnosis, an optional file backup (offered with its size in GB and an estimated copy time), repairs that each need a yes, and cleanup. Its `evals/` folder holds test cases in the `claude plugin eval` layout. The skill holds only general rules; each rescued PC's own story (hardware, evidence, what was tried, results, open items) goes in its own file in `cases/`, which is gitignored and stays local. This repository holds only the skill and its tools.

## Credits

PcRescue builds on other people's open-source work:

- **[SystemRescue](https://www.system-rescue.org/)** is the Linux rescue system on the stick, built on Arch Linux. Source: [gitlab.com/systemrescue/systemrescue-sources](https://gitlab.com/systemrescue/systemrescue-sources), licensed GPL-3.0-or-later. PcRescue doesn't change or redistribute it: you download the official ISO yourself, `write-usb.ps1` copies its contents onto the stick unchanged, and PcRescue's own files are added next to them through SystemRescue's configuration features (`sysrescue.d` YAML and `autorun`).
- **[Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH)** is Microsoft's Windows port of OpenSSH (source: [PowerShell/openssh-portable](https://github.com/PowerShell/openssh-portable)). Its installer from the [releases page](https://github.com/PowerShell/Win32-OpenSSH/releases) provides the SSH server in Windows mode when the PC doesn't already have one. The working computer uses Windows' built-in OpenSSH client.

## Kept out of this repository

Downloads (the SystemRescue ISO, the OpenSSH installer), SSH keys and saved targets in `keys/`, case logs, and anything copied from the faulty PC (crash dumps, event logs, personal files) stay local and are excluded by `.gitignore`.
