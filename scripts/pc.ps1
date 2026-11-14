<#
.SYNOPSIS
  Runs a command on the faulty PC (booted from the PcRescue stick) over the Ethernet cable.
  With no command, opens an interactive shell.

.DESCRIPTION
  Windows PowerShell 5 strips double quotes from arguments it passes to native programs,
  so a command is never handed to ssh as plain text. It is sent base64-encoded, written
  to a temporary script on the PC and run with bash. Quotes, newlines, pipes and
  non-ASCII names arrive exactly as written. The remote exit code is passed through.

  -Label is what the PC's status screen shows while the command runs, so whoever sits at
  that PC can follow along. Write it in plain words ("Reading disk health"). Without it,
  the first line of the command is shown.

.EXAMPLE
  .\scripts\pc.ps1 -Label 'Checking the SSD health' 'smartctl -H /dev/sdc'
.EXAMPLE
  .\scripts\pc.ps1 -Label 'Listing the disks' @'
  lsblk -o NAME,SIZE,FSTYPE
  echo "done"
  '@
.EXAMPLE
  .\scripts\pc.ps1
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Label,
  [Parameter(ValueFromRemainingArguments)][string[]]$Command
)

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
  '-o', 'ConnectTimeout=15',
  '-o', 'ConnectionAttempts=3',
  '-o', 'ServerAliveInterval=15',
  'root@169.254.77.77'
)
$ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"

if (-not $Command) {
  & $ssh @sshOptions
  exit $LASTEXITCODE
}

$script = ($Command -join ' ').Replace("`r`n", "`n")
if (-not $Label) {
  $Label = ($script -split "`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1).Trim()
}
if ($Label.Length -gt 70) { $Label = $Label.Substring(0, 67) + '...' }

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
$labelB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Label))
# No double quotes in here, so nothing for PowerShell 5 to strip. pcrescue-job records the
# command for the status screen; a stick without it just runs the script.
$remote = 'f=/tmp/pc-$$.sh; echo ' + $b64 + ' | base64 -d > $f; ' +
  'if [ -x /usr/local/bin/pcrescue-job ]; then /usr/local/bin/pcrescue-job $f ' + $labelB64 + '; else bash $f; fi; ' +
  'r=$?; rm -f $f; exit $r'

$previousEncoding = [Console]::OutputEncoding
try {
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  & $ssh @sshOptions $remote
} finally {
  [Console]::OutputEncoding = $previousEncoding
}
exit $LASTEXITCODE
