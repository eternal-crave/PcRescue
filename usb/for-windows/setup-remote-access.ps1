<#
.SYNOPSIS
  Lets the PcRescue laptop reach this PC's Windows over the direct Ethernet cable (SSH).
  Double-click "1 - Start remote access.cmd" to set it up, "3 - Remove remote access" to undo it.

.DESCRIPTION
  Set up (asks for administrator rights):
  - Uses Windows' OpenSSH Server if it is already installed. Otherwise installs only the
    server part of the OpenSSH-Win64-*.msi next to this script (Microsoft's Win32-OpenSSH).
  - Key login only: password and keyboard-interactive login are turned off, and the laptop's
    key (pcrescue.pub next to this script) is accepted for administrator accounts.
  - File copies (scp, sftp): the sftp line gets sftp-server.exe's full path, which OpenSSH 10
    for Windows needs. Every settings change is checked with "sshd -t" before the restart.
  - Firewall: port 22 opens only to link-local addresses (169.254.x.x), which is the direct
    cable to the laptop. A broader rule that the installer adds is switched off.
  - The SSH service starts with Windows, so access survives crashes and restarts.
  - Shows this PC's cable address and the login name to give to the laptop.
  - Installs the status screen (status.ps1) and the command recorder (job.ps1) into
    C:\ProgramData\PcRescue, opens the screen, and adds the scheduled task "PcRescue status"
    that opens it at every sign-in, with administrator rights so it can read the drives'
    SMART verdicts. Running it again refreshes these tools.
  Everything it changes is recorded in C:\ProgramData\PcRescue\state.json, and -Remove
  undoes exactly that: it uninstalls what it installed, or restores the previous settings
  of an OpenSSH Server that was there before.
#>
param([switch]$Remove)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
  if ($Remove) { $argList += '-Remove' }
  try {
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
  } catch {
    Write-Host 'Administrator rights are needed. Run it again and click Yes.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
  }
  exit
}

$stateDir = Join-Path $env:ProgramData 'PcRescue'
$statePath = Join-Path $stateDir 'state.json'
$sshData = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $sshData 'sshd_config'
$adminKeys = Join-Path $sshData 'administrators_authorized_keys'
$banner = Join-Path $sshData 'pcrescue-banner.txt'
$ruleName = 'PcRescue-SSH'
$taskName = 'PcRescue status'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Step([string]$text) { Write-Host "- $text" }
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8NoBom) }
function Save-State($state) { Write-Text $statePath ($state | ConvertTo-Json -Depth 4) }
function Get-OpenSshRules {
  @(Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $ruleName -and ($_.DisplayName -like '*OpenSSH*' -or $_.DisplayName -like '*sshd*') } |
    Select-Object -ExpandProperty Name)
}
function Get-MsiProductCode([string]$path) {
  # Read from the installer itself, so the uninstall later needs neither the stick nor the registry.
  $installer = New-Object -ComObject WindowsInstaller.Installer
  $database = $installer.OpenDatabase($path, 0)
  $view = $database.OpenView("SELECT Value FROM Property WHERE Property = 'ProductCode'")
  # COM calls without a result still emit $null; [void] keeps them out of the return value.
  [void]$view.Execute()
  $code = $view.Fetch().StringData(1)
  [void]$view.Close()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
  $code
}
function Install-StatusScreen {
  foreach ($f in 'status.ps1', 'job.ps1') { Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $stateDir $f) -Force }
  New-Item -ItemType Directory -Force (Join-Path $stateDir 'status\jobs'), (Join-Path $stateDir 'status\tasks') | Out-Null
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $stateDir 'status.ps1')`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Step 'Status screen installed; it opens at every sign-in.'
}
function Open-StatusScreen {
  $running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PcRescue\status.ps1*' }
  if (-not $running) { Start-ScheduledTask -TaskName $taskName }
}
function Stop-StatusScreen {
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PcRescue\status.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Get-CableAddress {
  @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '169.254.*' -and $_.AddressState -eq 'Preferred' } |
    Select-Object -ExpandProperty IPAddress)
}

function Get-SshdExe {
  $path = (Get-CimInstance Win32_Service -Filter "Name='sshd'").PathName
  if ($path -match '^"([^"]+)"') { $Matches[1] } else { ($path -split ' ')[0] }
}
# Returns $null when sshd accepts sshd_config, otherwise what sshd said.
function Test-SshdConfig {
  $ErrorActionPreference = 'Continue'
  $out = & (Get-SshdExe) -t -f $config 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { "$($out.Trim()) (exit $LASTEXITCODE)" }
}
# OpenSSH 10 for Windows can't start the sftp subsystem when sshd_config names it without its
# folder ("sftp-server.exe", the installer's default): scp and sftp then end with "Connection
# closed". Give it the full path next to sshd.exe. Returns $true when the line was changed.
function Set-SftpFullPath {
  $sftp = Join-Path (Split-Path (Get-SshdExe)) 'sftp-server.exe'
  if (-not (Test-Path $sftp)) { return $false }
  $before = [IO.File]::ReadAllText($config)
  $after = [regex]::Replace($before, '(?im)^([ \t]*Subsystem[ \t]+sftp[ \t]+)sftp-server\.exe(?=[ \t]*\r?$)', "`${1}`"$($sftp.Replace('\', '/'))`"")
  if ($after -eq $before) { return $false }
  Write-Text $config $after
  $problem = Test-SshdConfig
  if ($problem) {
    Write-Text $config $before
    Step "Note: sshd did not accept the full sftp path, so file copies may not work ($problem)."
    return $false
  }
  Step 'File copies: sshd now finds sftp-server.exe by its full path.'
  return $true
}

function Install-RemoteAccess {
  $keyLine = (Get-Content -Raw (Join-Path $PSScriptRoot 'pcrescue.pub')).Trim()
  if ($keyLine -notmatch '^ssh-[a-z0-9-]+ [A-Za-z0-9+/=]{40,}') { throw 'pcrescue.pub next to this script does not hold an SSH public key.' }
  $user = $env:USERNAME

  if (Test-Path $statePath) {
    Step 'Remote access is already set up; checking the service and refreshing the status screen.'
    $changed = Set-SftpFullPath
    Set-Service sshd -StartupType Automatic
    if ($changed) { Restart-Service sshd -Force } else { Start-Service sshd }
    Install-StatusScreen
    return $user
  }

  New-Item -ItemType Directory -Force $stateDir | Out-Null
  $state = [ordered]@{
    created          = (Get-Date).ToString('s')
    installedMsi     = $false
    productCode      = $null
    sshDataExisted   = (Test-Path $sshData)
    serviceExisted   = $false
    serviceStartType = $null
    serviceRunning   = $false
    configBackup     = $null
    keysExisted      = $false
    keysBackup       = $null
    disabledRules    = @()
  }

  # 1. Look for SSH servers already on this PC before installing anything
  $service = Get-Service sshd -ErrorAction SilentlyContinue
  $owners = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name } | Sort-Object -Unique)
  $others = @($owners | Where-Object { $_ -ne 'sshd' })
  if ($others.Count -gt 0) {
    throw "Another program already uses the SSH port (22): $($others -join ', '). Nothing was installed or changed. Tell Claude this name."
  }
  if (-not $service) {
    $installed = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
      Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'OpenSSH' } | Select-Object -First 1
    if ($installed) {
      throw "OpenSSH $($installed.DisplayVersion) is installed here without its server. Nothing was installed or changed. Tell Claude."
    }
    Step 'Checked: no SSH server on this PC yet.'
  }
  if ($service) {
    Step 'OpenSSH Server is already installed; using it.'
    $mode = (Get-CimInstance Win32_Service -Filter "Name='sshd'").StartMode
    $state.serviceExisted = $true
    $state.serviceStartType = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$mode]
    $state.serviceRunning = ($service.Status -eq 'Running')
    Save-State $state
  } else {
    $msi = Get-ChildItem $PSScriptRoot -Filter 'OpenSSH-Win64-*.msi' | Sort-Object Name | Select-Object -Last 1
    if (-not $msi) { throw 'OpenSSH Server is not installed, and no OpenSSH-Win64-*.msi is next to this script.' }
    $state.productCode = Get-MsiProductCode $msi.FullName
    $rulesBefore = Get-OpenSshRules
    Step "Installing OpenSSH Server ($($msi.Name)), about a minute..."
    $log = Join-Path $stateDir 'openssh-install.log'
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$($msi.FullName)`" ADDLOCAL=Server /qn /norestart /l*v `"$log`""
    if ($p.ExitCode -notin 0, 3010) { throw "The OpenSSH installer failed with code $($p.ExitCode). Its log: $log" }
    $state.installedMsi = $true
    Save-State $state
    # The installer opens port 22 to every network; keep only the cable-only rule below.
    foreach ($name in (Get-OpenSshRules | Where-Object { $_ -notin $rulesBefore })) {
      Disable-NetFirewallRule -Name $name
      $state.disabledRules += $name
    }
    Save-State $state
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'OpenSSH was installed, but its sshd service is missing.' }
  }

  # 2. First start creates the host keys and sshd_config
  Start-Service sshd
  for ($i = 0; $i -lt 20 -and -not (Test-Path $config); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-Path $config)) { throw "sshd did not create $config." }

  # 3. Key login only, plus a banner that tells the laptop the login name
  $text = [IO.File]::ReadAllText($config)
  if ($text -notmatch '# PcRescue begin') {
    $state.configBackup = Join-Path $stateDir 'sshd_config.before'
    Copy-Item $config $state.configBackup
    Save-State $state
    # sshd uses the first value it reads for each keyword, so these lines at the top win.
    # ChallengeResponseAuthentication is understood by old and new OpenSSH versions alike.
    $block = "# PcRescue begin`r`nPasswordAuthentication no`r`nChallengeResponseAuthentication no`r`n" +
      "PubkeyAuthentication yes`r`nBanner $($banner.Replace('\', '/'))`r`n# PcRescue end`r`n"
    Write-Text $config ($block + $text)
  }
  Write-Text $banner "PcRescue remote access. Login: $user`r`n"
  $problem = Test-SshdConfig
  if ($problem) {
    Write-Text $config $text
    throw "sshd did not accept the new settings, so they were undone: $problem"
  }
  Step 'Password login is off; only the laptop''s key can log in.'
  [void](Set-SftpFullPath)

  # 4. The laptop's key, for administrator accounts
  $state.keysExisted = Test-Path $adminKeys
  $existing = ''
  if ($state.keysExisted) {
    $state.keysBackup = Join-Path $stateDir 'administrators_authorized_keys.before'
    Copy-Item $adminKeys $state.keysBackup
    $existing = [IO.File]::ReadAllText($adminKeys)
  }
  Save-State $state
  if (-not $existing.Contains(($keyLine -split ' ')[1])) {
    $new = $existing.TrimEnd()
    if ($new) { $new += "`r`n" }
    Write-Text $adminKeys ($new + $keyLine + "`r`n")
  }
  # sshd ignores this file unless only Administrators and SYSTEM can access it.
  & icacls.exe $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not set the permissions of administrators_authorized_keys.' }

  # 5. Firewall: the cable only
  if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName 'PcRescue SSH (rescue cable only)' -Direction Inbound `
      -Protocol TCP -LocalPort 22 -RemoteAddress '169.254.0.0/16' -Action Allow -Profile Any | Out-Null
  }
  Step 'Firewall: SSH is open only to the direct cable (169.254.x.x).'

  # 6. Start with Windows, apply the settings
  Set-Service sshd -StartupType Automatic
  Restart-Service sshd -Force
  Step 'The SSH service starts with Windows.'
  Save-State $state

  # 7. The status screen
  Install-StatusScreen
  return $user
}

function Remove-RemoteAccess {
  if (-not (Test-Path $statePath)) {
    Write-Host 'Nothing to remove: remote access was not set up by PcRescue on this PC.'
    return
  }
  $state = Get-Content -Raw $statePath | ConvertFrom-Json
  Stop-StatusScreen
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Step 'Closed the status screen and removed its sign-in task.'
  Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
  Step 'Removed the cable-only firewall rule.'

  if ($state.installedMsi) {
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    if ($state.productCode) {
      Step 'Uninstalling OpenSSH Server, about a minute...'
      $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/x $($state.productCode) /qn /norestart"
      if ($p.ExitCode -notin 0, 3010, 1605) { throw "The OpenSSH uninstall failed with code $($p.ExitCode)." }
    } else {
      Write-Host 'Could not find the OpenSSH product code; uninstall "OpenSSH" in Settings > Apps.' -ForegroundColor Yellow
    }
    foreach ($name in @($state.disabledRules)) { if ($name) { Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue } }
    if (-not $state.sshDataExisted) { Remove-Item $sshData -Recurse -Force -ErrorAction SilentlyContinue }
    Step 'OpenSSH Server is uninstalled.'
  } else {
    if ($state.configBackup -and (Test-Path $state.configBackup)) {
      [IO.File]::WriteAllBytes($config, [IO.File]::ReadAllBytes($state.configBackup))
    }
    if ($state.keysExisted -and $state.keysBackup -and (Test-Path $state.keysBackup)) {
      [IO.File]::WriteAllBytes($adminKeys, [IO.File]::ReadAllBytes($state.keysBackup))
    } elseif (-not $state.keysExisted) {
      Remove-Item $adminKeys -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $banner -Force -ErrorAction SilentlyContinue
    if ($state.serviceStartType) { Set-Service sshd -StartupType $state.serviceStartType }
    if ($state.serviceRunning) { Restart-Service sshd -Force } else { Stop-Service sshd -Force -ErrorAction SilentlyContinue }
    Step 'OpenSSH Server is back to its previous settings.'
  }
  Remove-Item $stateDir -Recurse -Force
  Write-Host ''
  Write-Host '  Remote access is removed.' -ForegroundColor Green
}

try {
  if ($Remove) {
    Remove-RemoteAccess
  } else {
    $user = Install-RemoteAccess
    Write-Host '- Waiting for the cable address (up to 2 minutes after the cable is plugged in)...'
    $addresses = @()
    for ($i = 0; $i -lt 60 -and $addresses.Count -eq 0; $i++) {
      $addresses = Get-CableAddress
      if ($addresses.Count -eq 0) { Start-Sleep -Seconds 2 }
    }
    Write-Host ''
    if ($addresses.Count -gt 0) {
      Write-Host '  Remote access is ready.' -ForegroundColor Green
      Write-Host "  Tell Claude this address:  $($addresses -join ', ')" -ForegroundColor Yellow
      Write-Host "  Login name:                $user"
    } else {
      Write-Host '  Remote access is set up, but this PC has no cable address yet.' -ForegroundColor Yellow
      Write-Host '  Check that the Ethernet cable goes straight to the laptop, wait a minute,'
      Write-Host '  then run "1 - Start remote access" again to see the address.'
    }
    Write-Host '  The status screen opens in its own window and shows what Claude is doing.'
    Open-StatusScreen
  }
} catch {
  Write-Host ''
  Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host '  Take a photo of this window for Claude.'
}
Write-Host ''
Read-Host 'Press Enter to close'
