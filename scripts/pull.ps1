<#
.SYNOPSIS
  Copies a file or folder from the faulty PC (booted from the PcRescue stick) to the laptop.
  Uses scp, so binary files such as crash dumps arrive intact (PowerShell 5's '>' would corrupt them).

.EXAMPLE
  .\scripts\pull.ps1 /mnt/win/Windows/Minidump collected
#>
param(
  [Parameter(Mandatory)][string]$RemotePath,
  [string]$LocalDir = 'collected'
)

$projectRoot = Split-Path $PSScriptRoot -Parent
$key = Join-Path $projectRoot 'keys\pcrescue_ed25519'
$knownHosts = Join-Path $projectRoot 'keys\known_hosts'
if (-not [System.IO.Path]::IsPathRooted($LocalDir)) { $LocalDir = Join-Path $projectRoot $LocalDir }
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

# SystemRescue creates new host keys on every boot; forget the previous boot's key.
Remove-Item $knownHosts -ErrorAction SilentlyContinue

$scpOptions = @(
  '-r', '-p',
  '-i', $key,
  '-o', 'IdentitiesOnly=yes',
  '-o', 'StrictHostKeyChecking=no',
  '-o', "UserKnownHostsFile=$knownHosts",
  '-o', 'LogLevel=ERROR',
  '-o', 'ConnectTimeout=5'
)
& "$env:WINDIR\System32\OpenSSH\scp.exe" @scpOptions "root@169.254.77.77:$RemotePath" $LocalDir
exit $LASTEXITCODE
