<#
.SYNOPSIS
  Runs a PowerShell command on the faulty PC's Windows over the Ethernet cable, or opens a
  shell there. Needs "1 - Start remote access" from the stick's for-windows folder on that PC.

.DESCRIPTION
  -Address sets the PC's cable address (169.254.x.x, shown by "1 - Start remote access") and
  saves it in keys\win-target.txt. The login name is read from the PC's SSH banner, so only
  the address has to be typed. -User overrides it.

  The command runs in Windows PowerShell on the PC through job.ps1 (installed by "1 - Start
  remote access"), which shows it on the PC's status screen: WORKING while it runs, then
  under recent commands. -Label is what that screen shows; write it in plain words
  ("Reading disk health"). Without it, the first line of the command is shown. Script and
  label travel base64-encoded, so quotes, pipes, here-strings and non-ASCII names arrive
  exactly as written. Scripts too long for one command line are copied over first. The
  remote exit code is passed through. On a PC set up before job.ps1 existed, commands run
  directly, without the status screen.

  -Bind sets the laptop address the connection starts from, saved like -Address ('none'
  clears it). It's needed when the laptop shares its internet over the cable: the PC then has
  a 192.168.137.x address instead of 169.254.x.x, and its firewall still lets in only
  169.254.x.x. Give the laptop's Ethernet a second, link-local address (admin):
  New-NetIPAddress -InterfaceAlias Ethernet -IPAddress 169.254.77.1 -PrefixLength 16 -SkipAsSource $true
  then pass -Address 192.168.137.x -Bind 169.254.77.1.

  Windows keeps its SSH host key, so the first connection records it in
  keys\known_hosts_win and later connections check it.

.EXAMPLE
  .\scripts\win.ps1 -Address 169.254.12.34 -Label 'Reading the Windows version' 'Get-ComputerInfo -Property OsName, OsVersion'
.EXAMPLE
  .\scripts\win.ps1 -Label 'Checking the disks' 'Get-PhysicalDisk | Format-Table FriendlyName, HealthStatus, Size'
.EXAMPLE
  .\scripts\win.ps1
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Address,
  [string]$User,
  [string]$Bind,
  [string]$Label,
  [int]$Port = 22,
  [Parameter(ValueFromRemainingArguments)][string[]]$Command
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$key = Join-Path $projectRoot 'keys\pcrescue_ed25519'
$knownHosts = Join-Path $projectRoot 'keys\known_hosts_win'
$targetFile = Join-Path $projectRoot 'keys\win-target.txt'
$ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$scp = "$env:WINDIR\System32\OpenSSH\scp.exe"

$target = @{}
if (Test-Path $targetFile) {
  foreach ($line in Get-Content $targetFile) { if ($line -match '^(\w+)=(.*)$') { $target[$Matches[1]] = $Matches[2] } }
}
if ($Address) {
  if ($Address -ne $target['address']) { $target.Remove('user') }
  $target['address'] = $Address
}
if ($User) { $target['user'] = $User }
if ($Bind -eq 'none') { $target.Remove('bind') } elseif ($Bind) { $target['bind'] = $Bind }
if (-not $target['address']) { throw 'No address yet. Pass -Address 169.254.x.x as shown by "1 - Start remote access" on the PC.' }

$common = @(
  '-i', $key,
  '-o', "Port=$Port",
  '-o', 'IdentitiesOnly=yes',
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', "UserKnownHostsFile=$knownHosts",
  '-o', 'ConnectTimeout=15',
  '-o', 'ServerAliveInterval=15'
)
if ($target['bind']) { $common += @('-o', "BindAddress=$($target['bind'])") }

if (-not $target['user']) {
  # The banner is sent before login; "none" authentication fails right after it.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $probe = & $ssh @common -o PreferredAuthentications=none -o BatchMode=yes -o LogLevel=INFO "pcrescue@$($target['address'])" exit 2>&1 | Out-String
  $ErrorActionPreference = $previous
  if ($probe -match 'PcRescue remote access\. Login: (\S+)') {
    $target['user'] = $Matches[1]
  } else {
    throw "Could not read the login name from $($target['address']). ssh said: $($probe.Trim())"
  }
}
$saved = @("address=$($target['address'])", "user=$($target['user'])")
if ($target['bind']) { $saved += "bind=$($target['bind'])" }
Set-Content $targetFile -Value $saved -Encoding ASCII

$destination = "$($target['user'])@$($target['address'])"
$sshOptions = $common + @('-o', 'LogLevel=ERROR', $destination)

if (-not $Command) {
  & $ssh -t @sshOptions powershell.exe -NoLogo
  exit $LASTEXITCODE
}

$userScript = ($Command -join ' ').Replace("`r`n", "`n")
if (-not $Label) {
  $Label = ($userScript -split "`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1).Trim()
}
if ($Label.Length -gt 70) { $Label = $Label.Substring(0, 67) + '...' }
function ConvertTo-B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }

$runner = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass'
$job = 'C:\ProgramData\PcRescue\job.ps1'
$noJob = 9797   # what cmd returns when job.ps1 isn't installed on the PC
$labelB64 = ConvertTo-B64 $Label
$jobCommand = "if exist $job ($runner -File $job -Label $labelB64 -Script $(ConvertTo-B64 $userScript)) else (exit /b $noJob)"

# Remote error output must not stop this script: Windows PowerShell turns a native command's
# stderr into errors when the caller redirects it. The exit code reports the failure.
$ErrorActionPreference = 'Continue'
$previousEncoding = [Console]::OutputEncoding
try {
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  if ($jobCommand.Length -lt 7500) {
    & $ssh @sshOptions $jobCommand
    if ($LASTEXITCODE -eq $noJob) {
      # Set up before job.ps1 existed: run directly. Progress bars would arrive as CLIXML.
      $direct = '$ProgressPreference = ''SilentlyContinue''; [Console]::OutputEncoding = [Text.Encoding]::UTF8; ' + $userScript
      & $ssh @sshOptions "$runner -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($direct)))"
    }
  } else {
    # cmd.exe on the PC takes at most 8191 characters, so copy long scripts over first. The
    # first line deletes the copy once PowerShell has read it; the exit code stays.
    $local = Join-Path ([IO.Path]::GetTempPath()) ('pcrescue-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $selfDelete = 'Remove-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue' + "`n"
    [IO.File]::WriteAllText($local, $selfDelete + $userScript, (New-Object Text.UTF8Encoding $true))
    $remote = 'C:/ProgramData/PcRescue/' + (Split-Path $local -Leaf)
    & $scp -q @common "$local" "${destination}:$remote"
    $copied = $LASTEXITCODE -eq 0
    Remove-Item $local
    if (-not $copied) { throw 'Could not copy the script to the PC.' }
    $file = $remote.Replace('/', '\')
    & $ssh @sshOptions "if exist $job ($runner -File $job -Label $labelB64 -ScriptFile $file) else ($runner -File $file)"
  }
} finally {
  [Console]::OutputEncoding = $previousEncoding
}
exit $LASTEXITCODE
