<#
.SYNOPSIS
  Lists what an optional backup of the faulty PC's personal folders would copy: each
  folder's size, file count, biggest items and estimated copy time, plus a total.
  Read-only on both machines. It copies nothing.

.DESCRIPTION
  Needs the rescue PC reachable through scripts/pc.ps1, with the Windows drive mounted
  read-only at -WindowsRoot (default /mnt/win). For every user it measures Desktop,
  Documents, Pictures, Videos, Music, Downloads and OneDrive, plus any -Extra paths,
  with one du pass and one find pass per folder.

  Time estimate: from the laptop's wired link speed (about 75% of line rate is usable),
  or -MBps if you know better. -DriveMBps caps it at the drive's measured read speed.
  Without a measured drive speed, the upper end of the range assumes half speed.

  The raw measurement is saved to collected\backup-plan.tsv (gitignored), so the plan
  can be shown again with another speed via -TsvPath without measuring again.

.EXAMPLE
  .\scripts\backup-plan.ps1
.EXAMPLE
  .\scripts\backup-plan.ps1 -Extra '/mnt/win/Users/David/AppData/Local/Google/Chrome/User Data' -DriveMBps 60
#>
param(
  [string[]]$Extra = @(),
  [double]$MBps,
  [double]$DriveMBps,
  [string]$Destination,
  [string]$WindowsRoot = '/mnt/win',
  [string]$TsvPath,
  [switch]$ShowRemoteScript
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$inv = [System.Globalization.CultureInfo]::InvariantCulture
if (-not $Destination) { $Destination = Join-Path $projectRoot 'collected\backup' }

# --- The read-only measurement that runs on the rescue PC ---
function Get-ShQuoted([string]$s) { "'" + $s.Replace("'", "'\''") + "'" }
$extraLines = ($Extra | ForEach-Object {
  $name = ($_.TrimEnd('/') -split '/')[-1]
  "measure extra $(Get-ShQuoted $name) $(Get-ShQuoted $_)"
}) -join "`n"

$remote = @'
R=__ROOT__
TAB=$(printf '\t')
measure() { # owner label path
  [ -d "$3" ] && [ ! -L "$3" ] || return 0
  sizes=$(du -ab --max-depth=1 "$3" 2>/dev/null)
  # du prints the folder's own total last; the lines before it are its direct children.
  bytes=$(printf '%s\n' "$sizes" | tail -n 1 | cut -f1)
  top=$(printf '%s\n' "$sizes" | sed '$d' | sort -rn | head -n 3 | while IFS="$TAB" read -r b p; do printf '%s:%s/' "$b" "${p##*/}"; done)
  files=$(find "$3" -type f 2>/dev/null | wc -l)
  printf 'ROW|%s|%s|%s|%s|%s\n' "$1" "$2" "${bytes:-0}" "$files" "$top"
}
[ -d "$R/Users" ] || { echo "ERR|No Windows drive at $R. Mount it read-only first."; exit 3; }
for u in "$R"/Users/*; do
  name=${u##*/}
  case "$name" in 'All Users'|'Default'|'Default User'|'desktop.ini') continue;; esac
  [ -d "$u" ] && [ ! -L "$u" ] || continue
  for f in Desktop Documents Pictures Videos Music Downloads OneDrive; do measure "$name" "$f" "$u/$f"; done
done
__EXTRA__
'@
$remote = $remote.Replace('__ROOT__', (Get-ShQuoted $WindowsRoot)).Replace('__EXTRA__', $extraLines).Replace("`r`n", "`n")

if ($ShowRemoteScript) { return $remote }

# --- Measure (or read a saved measurement) ---
if ($TsvPath) {
  $lines = Get-Content -Encoding UTF8 -LiteralPath $TsvPath
} else {
  # pc.ps1 sends the script encoded, so its quotes survive Windows PowerShell 5.
  $previousEncoding = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $lines = @(& (Join-Path $PSScriptRoot 'pc.ps1') -Label 'Measuring what a backup would copy' $remote)
  } finally {
    [Console]::OutputEncoding = $previousEncoding
  }
  if (-not ($lines -like 'ROW|*') -and -not ($lines -like 'ERR|*')) {
    throw "No answer from the rescue PC (exit code $LASTEXITCODE). Is it booted from the stick and the cable connected?"
  }
  $saved = Join-Path $projectRoot 'collected\backup-plan.tsv'
  New-Item -ItemType Directory -Force -Path (Split-Path $saved) | Out-Null
  [IO.File]::WriteAllLines($saved, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
}
$err = @($lines -like 'ERR|*')
if ($err) { throw $err[0].Substring(4) }

$rows = foreach ($line in ($lines -like 'ROW|*')) {
  $p = $line.Split('|')
  $top = @($p[5].Split([char[]]'/', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
    $i = $_.IndexOf(':')
    [pscustomobject]@{ Bytes = [int64]$_.Substring(0, $i); Name = $_.Substring($i + 1) }
  })
  [pscustomobject]@{ Owner = $p[1]; Folder = $p[2]; Bytes = [int64]$p[3]; Files = [int64]$p[4]; Top = $top }
}

# --- Speed and formatting ---
if ($MBps) {
  $speedSource = "link speed set to $MBps MB/s"
} else {
  $nic = Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' -and $_.Status -eq 'Up' } |
    Sort-Object Speed -Descending | Select-Object -First 1
  if ($nic) {
    $MBps = [math]::Floor($nic.Speed / 8 / 1MB * 0.75)
    $speedSource = "cable at $($nic.LinkSpeed)"
  } else {
    $MBps = 89
    $speedSource = 'cable not connected, assuming 1 Gbps'
  }
}
$best = if ($DriveMBps) { [math]::Min($MBps, $DriveMBps) } else { $MBps }
$slowFactor = if ($DriveMBps) { 1.3 } else { 2 }

function Format-Size([double]$b) {
  if ($b -ge 1GB) { return [string]::Format($inv, '{0:0.0} GB', $b / 1GB) }
  if ($b -ge 1MB) { return [string]::Format($inv, '{0:0} MB', $b / 1MB) }
  return [string]::Format($inv, '{0:0} KB', $b / 1KB)
}
function Format-Time([double]$bytes) {
  $seconds = $bytes / ($best * 1MB)
  $lo = [math]::Max(1, [math]::Ceiling($seconds / 60))
  $hi = [math]::Max(1, [math]::Ceiling($seconds * $slowFactor / 60))
  if ($hi -ge 90) { return [string]::Format($inv, '{0:0.#}-{1:0.#} h', $lo / 60, $hi / 60) }
  if ($lo -eq $hi) { return "about $lo min" }
  return "$lo-$hi min"
}

$withData = @($rows | Where-Object Bytes -ge 1MB)
$empty = @($rows | Where-Object Bytes -lt 1MB)
$totalBytes = ($withData | Measure-Object Bytes -Sum).Sum
$totalFiles = ($withData | Measure-Object Files -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0; $totalFiles = 0 }
$free = (Get-PSDrive -Name (Split-Path -Qualifier $Destination).TrimEnd(':')).Free

$out = New-Object System.Collections.Generic.List[string]
$out.Add('Backup plan (nothing has been copied)')
$out.Add("  To:    $Destination ($(Format-Size $free) free)")
$driveNote = if ($DriveMBps) { ", drive reads $DriveMBps MB/s" } else { '; drive speed not measured, so the longer time assumes half speed' }
$out.Add("  Speed: about $best MB/s ($speedSource$driveNote)")
$out.Add('')
$out.Add([string]::Format($inv, '  {0,-32} {1,9} {2,9}  {3}', 'What', 'Size', 'Files', 'Time'))
foreach ($r in ($withData | Sort-Object @{ e = { $_.Owner -eq 'extra' } }, Owner, @{ e = 'Bytes'; Descending = $true })) {
  $label = if ($r.Owner -eq 'extra') { "Extra / $($r.Folder)" } else { "$($r.Owner) / $($r.Folder)" }
  $out.Add([string]::Format($inv, '  {0,-32} {1,9} {2,9:N0}  {3}', $label, (Format-Size $r.Bytes), $r.Files, (Format-Time $r.Bytes)))
  if ($r.Top.Count) {
    $out.Add('      biggest: ' + (($r.Top | ForEach-Object { "$($_.Name) ($(Format-Size $_.Bytes))" }) -join ', '))
  }
}
$out.Add([string]::Format($inv, '  {0,-32} {1,9} {2,9:N0}  {3}', 'Total', (Format-Size $totalBytes), $totalFiles, (Format-Time $totalBytes)))
$out.Add('')
if ($empty.Count) {
  $out.Add('  Empty, nothing to copy: ' + (($empty | ForEach-Object { if ($_.Owner -eq 'extra') { "Extra / $($_.Folder)" } else { "$($_.Owner) / $($_.Folder)" } }) -join ', '))
}
$out.Add('  Not included: Windows, Program Files, AppData (app settings, browser bookmarks and passwords), anything outside these folders.')
if ($withData | Where-Object Folder -eq 'OneDrive') {
  $out.Add('  OneDrive: files kept only in the cloud may not copy; they are already safe online.')
}
if ($totalBytes -gt 0.9 * $free) {
  $out.Add('  WARNING: this does not fit at the destination with room to spare. Pick fewer folders or another drive.')
}
$out
