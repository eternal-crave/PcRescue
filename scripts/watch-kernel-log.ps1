<#
.SYNOPSIS
  Streams the rescue PC's kernel log (and, with -Voltages, the motherboard's voltage and
  temperature readings every 5 seconds) to collected\pc-kernel.log on the laptop, so that if
  the PC freezes or crashes, its last messages are already safe here. Read-only on the PC.

.DESCRIPTION
  Reconnects after the connection drops, until -Minutes have passed. Run it in the
  background, then read the end of the log after a crash:
    Get-Content collected\pc-kernel.log -Tail 60
  Lines starting with "SENSORS" are the readings; "=== " lines mark connects and drops.
  It talks to ssh directly instead of through pc.ps1, so it doesn't sit on the PC's
  status screen as a never-ending WORKING command.

.EXAMPLE
  .\scripts\watch-kernel-log.ps1 -Voltages
#>
param(
  [string]$LogPath,
  [int]$Minutes = 240,
  [switch]$Voltages
)

$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $LogPath) { $LogPath = Join-Path $projectRoot 'collected\pc-kernel.log' }
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
$key = Join-Path $projectRoot 'keys\pcrescue_ed25519'
$knownHosts = Join-Path $projectRoot 'keys\known_hosts'
$ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$sshOptions = @(
  '-i', $key,
  '-o', 'IdentitiesOnly=yes',
  '-o', 'StrictHostKeyChecking=no',
  '-o', "UserKnownHostsFile=$knownHosts",
  '-o', 'LogLevel=ERROR',
  '-o', 'ConnectTimeout=15',
  '-o', 'ServerAliveInterval=5',
  '-o', 'ServerAliveCountMax=3',
  'root@169.254.77.77'
)

function Write-Log([string]$line) { [IO.File]::AppendAllText($LogPath, $line + "`n") }

$first = $true
$deadline = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt $deadline) {
  # The whole kernel log on the first connection, only new lines after a reconnect.
  $follow = if ($first) { 'dmesg --follow --time-format iso' } else { 'dmesg --follow-new --time-format iso' }
  $remote = "$follow &`n"
  if ($Voltages) {
    $remote += @'
for m in nct6775 it87; do modprobe $m 2>/dev/null; done
while sleep 5; do
  printf 'SENSORS %s %s\n' "$(date -Is)" "$(sensors -A 2>/dev/null | grep -E '^[A-Za-z0-9+. ]+:' | grep -vE 'fan|pwm|RPM' | sed -E 's/ +\(.*//; s/ +/ /g' | tr '\n' ';')"
done
'@
  } else {
    $remote += "wait`n"
  }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
  Write-Log "=== connecting $(Get-Date -Format s)"
  & $ssh @sshOptions "echo $b64 | base64 -d > /tmp/watch.sh; exec bash /tmp/watch.sh" 2>&1 |
    ForEach-Object { Write-Log "$_" }
  Write-Log "=== connection lost $(Get-Date -Format s) (exit $LASTEXITCODE)"
  $first = $false
  Start-Sleep -Seconds 5
}
