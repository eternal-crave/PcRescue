# PcRescue

Tooling for repairing a Windows PC that keeps crashing with `CRITICAL_PROCESS_DIED` (stop code `0xEF`), even in Safe Mode, without relying on the broken Windows install.

The faulty PC boots SystemRescue (Linux) from a USB stick. The laptop connects to it over a direct Ethernet cable with SSH, then diagnoses the drive, RAM, crash dumps and event logs from there.

A [Skillforge](https://github.com/eternal-crave/skillforge) shard, kept in its own repo because it ships with its rescue-USB tools and scripts.

## How it works

- `usb/` holds files added to the stick on top of the SystemRescue ISO:
  - `sysrescue.d/500-pcrescue.yaml` turns off the SystemRescue firewall, authorizes the laptop's SSH key and skips the keypress pause after startup scripts.
  - `autorun/autorun` runs once at boot. It authorizes the key again (in case the YAML option is ignored), allows key-only root login, gives every wired port the fixed address `169.254.77.77/16`, and installs the tools in `pcrescue/`.
  - `pcrescue/status.sh` is the status screen on the faulty PC's own monitor (Alt+F8). It lists the command running now, long tasks with a progress bar, Linux uptime, CPU temperature and load, memory, the cable, every mounted drive with read-only or READ-WRITE, files being copied to the laptop, and recent commands. A small pixel heart pulses calmly beside the "This PC" panel next to a slow ECG line, and goes grey and flat when the cable is out.
  - `pcrescue/job.sh` records each command from `pc.ps1` for that screen. `pcrescue/readtest.sh` reads a whole disk once, read-only, and logs slow or failing areas.
- With no router on the cable, Windows gives the laptop's Ethernet port a `169.254.x.x` address by itself, so both ends share a network with no settings changed on the laptop.
- SystemRescue boots only from a FAT32 volume whose label matches the ISO's label (for example `RESCUE1303`). `scripts/write-usb.ps1` reads the label from the ISO and checks it against the ISO's boot config.

## Usage

1. Download the SystemRescue ISO and its `.sha256` file into `downloads/`, then check the hash.
2. Create the SSH key (kept in `keys/`, ignored by Git):

   ```powershell
   ssh-keygen -t ed25519 -N '""' -C pcrescue-laptop -f keys\pcrescue_ed25519
   ```

3. Write the stick from an elevated PowerShell. This erases the whole stick:

   ```powershell
   .\scripts\write-usb.ps1 -DiskNumber <n> -ExpectedName '<FriendlyName from Get-Disk>' `
     -IsoPath .\downloads\systemrescue-13.03-amd64.iso -PublicKeyPath .\keys\pcrescue_ed25519.pub
   ```

4. On the faulty PC: turn off Secure Boot (SystemRescue does not support it), boot the stick's UEFI entry, and connect the Ethernet cable to the laptop.
5. From the laptop:

   ```powershell
   .\scripts\pc.ps1 -Label 'Listing the disks' 'lsblk'      # run a command; the label shows on the PC's screen
   .\scripts\pc.ps1                                          # open a shell
   .\scripts\pull.ps1 /mnt/win/Windows/Minidump collected    # copy files back (binary-safe)
   .\scripts\backup-plan.ps1                                 # what a backup would copy: sizes, files, time (read-only)
   .\scripts\install-status-screen.ps1                       # refresh the PC-side tools without rewriting the stick
   .\scripts\watch-kernel-log.ps1 -Voltages                  # stream kernel log + sensors to collected\ (catches freezes)
   ```

   `pc.ps1` sends commands base64-encoded, so quotes and multi-line here-strings survive Windows PowerShell 5. For long jobs use `systemd-run` on the PC, for example `systemd-run --unit=pcrescue-readtest-sdX --collect /usr/local/bin/pcrescue-readtest /dev/sdX`, so a dropped connection doesn't stop them.

## Claude skill

`.claude/skills/pc-rescue/` teaches Claude Code the whole workflow when it runs in this folder. It covers the safety briefing and explicit consent, BitLocker and Secure Boot preparation, building the stick, connecting, read-only diagnosis, an optional file backup (offered with its size in GB and an estimated copy time), repairs that each need a yes, and cleanup. Its `evals/` folder holds test cases in the `claude plugin eval` layout. The skill holds only general rules; each rescued PC's own story (hardware, evidence, what was tried, results, open items) goes in its own file in `cases/`, which is gitignored and stays local. This repository holds only the skill and its tools.

Turn Secure Boot back on when finished. If the Windows drive uses BitLocker, Windows asks for the recovery key after Secure Boot changes, and Linux needs that key to read the drive.

## Kept out of this repository

The SystemRescue ISO, SSH keys, and anything copied from the faulty PC (crash dumps, event logs, personal files) stay local and are excluded by `.gitignore`.
