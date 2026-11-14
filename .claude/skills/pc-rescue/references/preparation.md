# Preparation and connection details

## BitLocker on the faulty PC

**Is it encrypted?**
- From any browser: account.microsoft.com/devices/recoverykey lists recovery keys for devices signed in with that Microsoft account. A key listed for that PC means the drive was encrypted at some point (Windows 11 often turns on "Device encryption" automatically).
- In the Windows recovery console (Troubleshoot → Advanced options → Command Prompt): `manage-bde -status`. A "Protection On" or "Locked" status means encrypted.
- If the recovery console asks for a recovery key before opening the Command Prompt, the drive is encrypted.

**Suspend, don't decrypt.** In the recovery console, the user unlocks the drive and suspends protection, typing the key themselves. First check which letter Windows has there; it is often not `C:`:

```bat
manage-bde -status
manage-bde -unlock X: -RecoveryPassword <the 48 digits, typed by the user>
manage-bde -protectors -disable X: -RebootCount 0
```

`-RebootCount 0` keeps protection suspended until it is explicitly resumed, through all the crash restarts. Suspension leaves the data encrypted but stops Windows asking for the key after firmware changes. Afterwards, `manage-bde -status` should show "Protection Off" while the conversion status stays "Fully Encrypted". Resume it at cleanup with `manage-bde -protectors -enable C:` (recovery console) or `Resume-BitLocker -MountPoint C:` (Windows). Full decryption (`manage-bde -off`) rewrites the whole drive for hours. On a PC that crashes every few minutes that's slow and risky, so don't suggest it.

If the recovery console isn't reachable, skip suspension. The user writes the key down before changing firmware settings and types it if Windows asks.

**Reading an encrypted drive from SystemRescue.** The user types the key at the faulty PC's own keyboard, not through Claude. Prefer read-only:

```sh
cryptsetup open --type bitlk --readonly /dev/<partition> bitlk   # prompts for the key
mkdir -p /mnt/win && ntfs-3g -o ro /dev/mapper/bitlk /mnt/win
```

`dislocker` is also on the stick (`dislocker -V /dev/<partition> -p -- /mnt/bitlocker`, then mount `/mnt/bitlocker/dislocker-file`). If protection was suspended, dislocker's clear-key mode (`-c`) may open it without the key.

## Secure Boot

SystemRescue's boot loader isn't signed for Secure Boot. Open firmware setup with Del, F2, F10 or Esc at power-on, or from the recovery console: Troubleshoot → Advanced options → UEFI Firmware Settings. The setting is usually under Boot, Security or Authentication. On some ASUS boards it's "OS Type" → "Other OS".

- Set it to **Disabled**. Don't choose "Delete/Clear Secure Boot keys". If that's the only option, stop and look up the board's manual.
- A phone photo of the screen first makes restoring it easy.
- Leave TPM/PTT/fTPM, storage mode (AHCI/RAID/RST/VMD), UEFI vs. legacy/CSM and boot order alone. Don't "Load defaults", clear the TPM or update the BIOS.
- If the stick doesn't appear in the boot menu, turn off the firmware's "Fast Boot" and try again.

Turning Secure Boot off doesn't touch the data. On encrypted drives without suspension, Windows asks for the recovery key at its next start. Turn Secure Boot back on at cleanup.

## Laptop checks

```powershell
Get-NetAdapter -Physical | Select-Object Name, InterfaceDescription, Status   # an Ethernet adapter must exist
Get-Command ssh, scp                                                            # built-in OpenSSH client
```

## Connection troubleshooting

The stick gives every wired port on the faulty PC `169.254.77.77/16`. Windows gives its own Ethernet port a `169.254.x.x` address about a minute after the cable connects and no router answers. Check in this order:

1. Laptop side: `Get-NetIPAddress -InterfaceAlias Ethernet -AddressFamily IPv4` should show `169.254.*`. "Disconnected" means a cable or port problem; check the link lights at both ends.
2. `Test-Connection 169.254.77.77 -Count 2`. No answer means the PC side isn't configured.
3. Ask the user to type `ip -br addr` on the faulty PC and read out the wired line. If `169.254.77.77` is missing, the autorun didn't run. They type `sh /run/archiso/bootmnt/autorun/autorun`.
4. If ping works but SSH doesn't: on the PC, `systemctl status sshd` and `cat /root/.ssh/authorized_keys`. On the laptop, run `.\scripts\pc.ps1` with `-v` added to the ssh options in the script, temporarily.
5. If the PC is plugged into a home router instead, it won't have `169.254.77.77`. Use the direct cable.
6. An occasional `Connection timed out` while ping answers is the link dropping a few packets. The scripts already try 3 times; run the command once more before troubleshooting.
7. A link at 100 Mbps (`Get-NetAdapter` on the laptop, `ethtool <device>` on the PC) is usually the PC's network chip, not the cable. Many older boards have a 100 Mbps network chip. Commands are unaffected; big copies run at about 10 MB/s.
8. The PC's monitor shows the status screen on Alt+F8 once the stick has booted. If it's missing, `.\scripts\install-status-screen.ps1` installs it on the running system.
