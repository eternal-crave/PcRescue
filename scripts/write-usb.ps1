<#
.SYNOPSIS
  Writes a UEFI-bootable SystemRescue USB stick with PcRescue's SSH setup.

.DESCRIPTION
  Refuses any disk that is not USB, is a boot/system disk, is over 64 GB, or whose name
  differs from -ExpectedName.

  SystemRescue boots only from a FAT32 volume whose label matches the ISO's label
  (archisolabel=, e.g. RESCUE1303), so the label is read from the ISO's boot config.

  The ISO is unpacked with Windows' tar.exe (libarchive), which keeps the Rock Ridge
  file names. Do not copy from a mounted ISO: Windows shows the plain ISO 9660 names
  (upper case, '-' turned into '_'), which breaks paths like boot/grub/x86_64-efi.

  Default mode wipes the stick to one MBR FAT32 partition and needs an elevated shell.
  -ReuseVolume keeps the existing partition when it is already FAT32 with the right
  label, deletes its contents and rewrites them; that does not need elevation.

  PcRescue files from usb/ are added last, with the laptop's public key filled in,
  LF line endings and no BOM.

.EXAMPLE
  .\scripts\write-usb.ps1 -DiskNumber 1 -ExpectedName 'TOSHIBA Transmemory' `
    -IsoPath .\downloads\systemrescue-13.03-amd64.iso -PublicKeyPath .\keys\pcrescue_ed25519.pub
#>
param(
  [Parameter(Mandatory)][int]$DiskNumber,
  [Parameter(Mandatory)][string]$ExpectedName,
  [Parameter(Mandatory)][string]$IsoPath,
  [Parameter(Mandatory)][string]$PublicKeyPath,
  [switch]$ReuseVolume,
  [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($LogPath) { Start-Transcript -Path $LogPath -Force | Out-Null }
$failed = $false

try {
  # --- Guard: make sure this is the stick we mean ---
  $disk = Get-Disk -Number $DiskNumber
  if ($disk.BusType -ne 'USB') { throw "Disk $DiskNumber is not a USB disk (BusType=$($disk.BusType))." }
  if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a boot or system disk." }
  if ($disk.FriendlyName -ne $ExpectedName) { throw "Disk $DiskNumber is '$($disk.FriendlyName)', expected '$ExpectedName'." }
  if ($disk.Size -gt 64GB) { throw "Disk $DiskNumber is larger than 64 GB." }

  # --- Public key: "type base64" without the comment ---
  $keyParts = (Get-Content -Raw $PublicKeyPath).Trim() -split '\s+'
  if ($keyParts.Count -lt 2 -or $keyParts[0] -notmatch '^ssh-') { throw "Not an SSH public key: $PublicKeyPath" }
  $pubKey = "$($keyParts[0]) $($keyParts[1])"

  # --- Volume label from the ISO's boot configs ---
  $IsoPath = (Resolve-Path $IsoPath).Path
  $bootConfigs = (& tar.exe -xOf $IsoPath boot/grub/grubsrcd.cfg isolinux/isolinux.cfg sysresccd/boot/syslinux/sysresccd_sys.cfg 2>$null) -join "`n"
  $labels = [regex]::Matches($bootConfigs, 'archisolabel=([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
  if (@($labels).Count -ne 1 -or $labels -notmatch '^RESCUE\d+$') { throw "Could not read a single RESCUE label from the ISO (found: $($labels -join ', '))." }
  $label = [string]$labels
  Write-Host "ISO label: $label"

  if ($ReuseVolume) {
    # --- Keep the partition; it must already be FAT32 with the right label ---
    $partitions = @(Get-Partition -DiskNumber $DiskNumber | Where-Object DriveLetter -match '[A-Z]')
    if ($partitions.Count -ne 1) { throw "Expected exactly one lettered partition on disk $DiskNumber, found $($partitions.Count)." }
    $volume = Get-Volume -DriveLetter $partitions[0].DriveLetter
    if ($volume.FileSystem -ne 'FAT32' -or $volume.FileSystemLabel -ne $label) {
      throw "Volume is $($volume.FileSystem) '$($volume.FileSystemLabel)'; -ReuseVolume needs FAT32 '$label'. Run without -ReuseVolume."
    }
    $usbRoot = "$($partitions[0].DriveLetter):\"
    Write-Host "Deleting current contents of $usbRoot..."
    Get-ChildItem $usbRoot -Force | Where-Object Name -ne 'System Volume Information' | Remove-Item -Recurse -Force
  } else {
    # --- Wipe and partition: one MBR FAT32 partition, marked active ---
    Write-Host "Erasing disk $DiskNumber ($($disk.FriendlyName), $([math]::Round($disk.Size/1GB,1)) GB)..."
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    if ((Get-Disk -Number $DiskNumber).PartitionStyle -eq 'RAW') {
      Initialize-Disk -Number $DiskNumber -PartitionStyle MBR
    } else {
      Set-Disk -Number $DiskNumber -PartitionStyle MBR
    }
    $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -MbrType FAT32 -IsActive
    $partition | Format-Volume -FileSystem FAT32 -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
    $partition | Add-PartitionAccessPath -AssignDriveLetter
    for ($try = 0; $try -lt 10; $try++) {
      $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
      if ($partition.DriveLetter -match '[A-Z]') { break }
      Start-Sleep -Seconds 1
    }
    if ($partition.DriveLetter -notmatch '[A-Z]') { throw 'The new partition did not get a drive letter.' }
    $usbRoot = "$($partition.DriveLetter):\"
    Write-Host "Formatted $usbRoot as FAT32 '$label'."
  }

  # --- Unpack the ISO with its real (Rock Ridge) file names ---
  Write-Host 'Unpacking SystemRescue onto the stick (several minutes on a USB 2.0 stick)...'
  & tar.exe -xf $IsoPath -C $usbRoot
  if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE." }

  # --- PcRescue files, LF line endings, no BOM ---
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $overlay = Join-Path $projectRoot 'usb'
  Get-ChildItem $overlay -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($overlay.Length).TrimStart('\')
    $target = Join-Path $usbRoot $relative
    $text = [System.IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n").Replace('__PUBKEY__', $pubKey)
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    [System.IO.File]::WriteAllText($target, $text, $utf8NoBom)
    Write-Host "Added $relative"
  }
  Write-Host "DONE: $usbRoot is ready."
} catch {
  $failed = $true
  Write-Host "FAILED: $($_.Exception.Message)"
} finally {
  if ($LogPath) { Stop-Transcript | Out-Null }
}
if ($failed) { exit 1 }
