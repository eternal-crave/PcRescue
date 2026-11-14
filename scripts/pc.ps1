<#
.SYNOPSIS
  Runs a command on the faulty PC (booted from the PcRescue stick) over the Ethernet cable.
  With no command, opens an interactive shell.

.EXAMPLE
  .\scripts\pc.ps1 'smartctl -H /dev/nvme0'
.EXAMPLE
  .\scripts\pc.ps1
#>
param([Parameter(ValueFromRemainingArguments)][string[]]$Command)

$projectRoot = Split-Path $PSScriptRoot -Parent
$key = Join-Path $projectRoot 'keys\pcrescue_ed25519'
$knownHosts = Join-Path $projectRoot 'keys\known_hosts'

# SystemRescue creates new host keys on every boot; forget the previous boot's key.
Remove-Item $knownHosts -ErrorAction SilentlyContinue

$sshOptions = @(
  '-i', $key,
  '-o', 'IdentitiesOnly=yes',
  '-o', 'StrictHostKeyChecking=no',
  '-o', "UserKnownHostsFile=$knownHosts",
  '-o', 'LogLevel=ERROR',
  '-o', 'ConnectTimeout=5',
  '-o', 'ServerAliveInterval=15',
  'root@169.254.77.77'
)
& "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshOptions @Command
exit $LASTEXITCODE
