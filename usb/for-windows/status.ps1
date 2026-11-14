<#
  PcRescue status screen for the faulty PC's own monitor, Windows edition. It mirrors the
  SystemRescue screen (usb/pcrescue/status.sh): what the laptop is doing right now, long tasks
  with a progress bar, how long Windows has stayed up, CPU load, memory, the cable, the
  drives, copies with the laptop and the last commands, with the same small pulsing heart and
  ECG line beside the "This PC" panel (grey and flat when the cable is out).

  It only reads, apart from removing stale job files. Inputs, written by job.ps1:
    status\jobs\<pid>    start-epoch|label                  while a win.ps1 command runs
    status\log           end-epoch|result|seconds|label     one line per finished command
    status\tasks\<name>  label|percent|detail               long background work
  Installed into C:\ProgramData\PcRescue by "1 - Start remote access", which also opens it,
  and started at every sign-in until "3 - Remove remote access" removes it.

  -Frames n draws n frames as plain text to the output and exits (for testing).
#>
param([int]$Frames = 0)

$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:ProgramData 'PcRescue'
$state = Join-Path $root 'status'
New-Item -ItemType Directory -Force "$state\jobs", "$state\tasks" | Out-Null
if (-not (Test-Path "$state\log")) { [IO.File]::WriteAllText("$state\log", '') }
$test = $Frames -gt 0

$E = [char]27
$N = "$E[0m"; $B = "$E[1m"; $DIM = "$E[2m"
$RED = "$E[31m"; $GRN = "$E[32m"; $YEL = "$E[33m"; $CYN = "$E[36m"
$SPIN = '|/-\'
$UP = [string][char]0x2580; $LO = [string][char]0x2584; $FULL = [string][char]0x2588
$HEART_COL = 80
$HEART_ROWS = 6

if (-not $test) {
  Add-Type -Namespace PcRescue -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr w, int c);
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct FontInfo { public int cbSize; public int nFont; public short dx; public short dy; public int family; public int weight;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string face; }
[DllImport("kernel32.dll")] public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref FontInfo f);
'@
  $out = [PcRescue.Con]::GetStdHandle(-11)
  $mode = 0
  [void][PcRescue.Con]::GetConsoleMode($out, [ref]$mode)
  [void][PcRescue.Con]::SetConsoleMode($out, $mode -bor 4)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
  # A large font, readable from across the room, then fill the screen.
  $font = New-Object PcRescue.Con+FontInfo
  $font.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($font)
  $font.dy = 28; $font.family = 54; $font.weight = 400; $font.face = 'Consolas'
  [void][PcRescue.Con]::SetCurrentConsoleFontEx($out, $false, [ref]$font)
  [void][PcRescue.Con]::ShowWindow([PcRescue.Con]::GetConsoleWindow(), 3)
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  [Console]::CursorVisible = $false
  $Host.UI.RawUI.WindowTitle = 'PcRescue status'
  [Console]::Write("$E[0m$E[?7l$E[2J")   # no line wrap: long lines are cut instead of scrolling
}

# --- Machine readings, taken in the background so the animation stays smooth ---
$S = [hashtable]::Synchronized(@{ ready = $false })
$sampler = {
  param($S, [bool]$once)
  $ErrorActionPreference = 'SilentlyContinue'
  $last = $null; $i = 0
  while ($true) {
    $os = Get-CimInstance Win32_OperatingSystem
    $S.up = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
    $S.memTotal = [double]$os.TotalVisibleMemorySize * 1KB
    $S.memUsed = ([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) * 1KB
    $S.load = [int]((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average)

    # The cable to the laptop: the adapter with a link-local (169.254.x.x) address.
    $ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '169.254.*' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1
    $nic = if ($ip) { Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex } else { Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' } | Select-Object -First 1 }
    $S.netUp = ($nic -and $nic.Status -eq 'Up')
    $S.speed = if ($nic) { $nic.LinkSpeed } else { '?' }
    $S.address = if ($ip) { $ip.IPAddress } else { $null }
    $now = Get-Date
    if ($nic) {
      $st = Get-NetAdapterStatistics -Name $nic.Name
      if ($last -and $last.name -eq $nic.Name) {
        $dt = ($now - $last.time).TotalSeconds
        if ($dt -gt 0) { $S.tx = [math]::Max(0, ($st.SentBytes - $last.tx) / $dt); $S.rx = [math]::Max(0, ($st.ReceivedBytes - $last.rx) / $dt) }
      }
      $last = @{ name = $nic.Name; time = $now; tx = $st.SentBytes; rx = $st.ReceivedBytes }
    }
    $S.laptop = @(Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue).Count -gt 0
    $S.copying = [bool](Get-Process sftp-server, scp -ErrorAction SilentlyContinue)

    if ($i % 10 -eq 0) {
      # Drives: letter, size, free, model, and the drive's own SMART verdict.
      $failing = @{}
      foreach ($f in Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue) {
        $failing[($f.InstanceName -replace '_\d+$', '').ToUpper()] = $f.PredictFailure
      }
      $models = @{}
      foreach ($d in Get-CimInstance Win32_DiskDrive) {
        $models[[int]$d.Index] = @{ model = ($d.Model -replace '^ATA ', '').Trim(); failing = $failing[$d.PNPDeviceID.ToUpper()] }
      }
      $S.drives = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter | ForEach-Object {
        $p = Get-Partition -DriveLetter $_.DriveLetter
        $m = $models[[int]$p.DiskNumber]
        [pscustomobject]@{ letter = $_.DriveLetter; size = $_.Size; free = $_.SizeRemaining; model = $m.model; failing = $m.failing; health = "$($_.HealthStatus)" }
      })
    }
    $S.ready = $true
    if ($once) { break }
    $i++
    Start-Sleep -Milliseconds 1000
  }
}
if ($test) {
  & $sampler $S $true
} else {
  $ps = [powershell]::Create().AddScript($sampler).AddArgument($S).AddArgument($false)
  [void]$ps.BeginInvoke()
}

function Repeat([string]$s, [int]$n) { if ($n -le 0) { '' } else { $s * $n } }
function Clock([int]$s) { '{0}:{1:00}' -f [math]::Floor($s / 60), ($s % 60) }
function LongClock([int]$s) { '{0}:{1:00}:{2:00}' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60), ($s % 60) }
function Size([double]$b) {
  if ($b -ge 1GB) { '{0:0.0} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:0} MB' -f ($b / 1MB) } else { '{0:0} KB' -f ($b / 1KB) }
}
function Plain([string]$s) { $s -replace "$E\[[0-9;?]*[a-zA-Z]", '' }

# A block bouncing in a track while the laptop runs something; a slow dot while waiting.
function BusyAnim([int]$frame) {
  $w = 20; $b = 4; $span = $w - $b; $pos = [math]::Floor($frame / 2) % (2 * $span)
  if ($pos -gt $span) { $pos = 2 * $span - $pos }
  "$CYN[$(Repeat ' ' $pos)$B$(Repeat '#' $b)$N$CYN$(Repeat ' ' ($w - $b - $pos))] $($SPIN[[math]::Floor($frame / 2) % 4])$N"
}
function IdleAnim([int]$frame) {
  $w = 20; $pos = [math]::Floor($frame / 4) % (2 * ($w - 1))
  if ($pos -gt $w - 1) { $pos = 2 * ($w - 1) - $pos }
  "$DIM[$(Repeat ' ' $pos).$(Repeat ' ' ($w - 1 - $pos))]  $N"
}

# --- The heart: the same two 13x12 pixel frames as on SystemRescue ---
$heartRest = '.............', '...XX...XX...', '..XooX.XXXX..', '.XoXXXXXXXXX.', '.XXXXXXXXXXX.', '..XXXXXXXXX..',
  '...XXXXXXX...', '....XXXXX....', '.....XXX.....', '......X......', '.............', '.............'
$heartBig = '..XXX...XXX..', '.XooXX.XXXXX.', 'XoXXXXXXXXXXX', 'XXXXXXXXXXXXX', 'XXXXXXXXXXXXX', '.XXXXXXXXXXX.',
  '..XXXXXXXXX..', '...XXXXXXX...', '....XXXXX....', '.....XXX.....', '......X......', '.............'
function Fg([char]$ch, [bool]$flat) { if ($flat) { '1;30' } elseif ($ch -ceq 'o') { '1;31' } else { '31' } }
function Cell([char]$t, [char]$b, [bool]$flat) {
  if ($t -eq '.' -and $b -eq '.') { return "$E[0m " }
  if ($b -eq '.') { return "$E[0;$(Fg $t $flat)m$UP" }
  if ($t -eq '.') { return "$E[0;$(Fg $b $flat)m$LO" }
  if ($t -ceq $b -or $flat) { return "$E[0;$(Fg $t $flat)m$FULL" }
  if ($t -ceq 'o') { "$E[0;1;31;41m$UP" } else { "$E[0;1;31;41m$LO" }
}
function HeartRows($pic, [bool]$flat) {
  for ($r = 0; $r -lt $HEART_ROWS; $r++) {
    $line = ''
    for ($c = 0; $c -lt 13; $c++) { $line += Cell $pic[2 * $r][$c] $pic[2 * $r + 1][$c] $flat }
    $line + "$E[0m   "
  }
}
$heartCache = @{ rest = @(HeartRows $heartRest $false); big = @(HeartRows $heartBig $false); flat = @(HeartRows $heartRest $true) }
$wave = 5, -1, 0, 0, 1, 2, 1, 0, 0, 0, 1, 0
function Picture([int]$T, [int]$W, [bool]$flat) {
  $P = 12; $H = $HEART_ROWS * 2; $base = $H - 4; $gap = 3
  $heart = if ($flat) { $heartCache.flat } elseif (($T % $P) -lt 2) { $heartCache.big } else { $heartCache.rest }
  $pen = $T % $W
  $age = New-Object int[] $W; $y = New-Object int[] $W
  $on = New-Object 'bool[,]' $W, $H
  for ($x = 0; $x -lt $W; $x++) {
    $age[$x] = $pen - $x; if ($age[$x] -lt 0) { $age[$x] += $W }
    if ($age[$x] -gt $W - $gap -or $T - $age[$x] -lt 0) { $y[$x] = -1; continue }
    $y[$x] = $base - $(if ($flat) { 0 } else { $wave[($T - $age[$x]) % $P] })
  }
  for ($x = 0; $x -lt $W; $x++) {
    if ($y[$x] -lt 0) { continue }
    $on[$x, $y[$x]] = $true
    if ($x -gt 0 -and $y[$x - 1] -ge 0) {
      $yLow = [math]::Min($y[$x - 1], $y[$x]); $yHigh = [math]::Max($y[$x - 1], $y[$x])  # not $lo: names ignore case, and $LO is the half block
      for ($k = $yLow + 1; $k -lt $yHigh; $k++) { $on[$x, $k] = $true }
    }
  }
  for ($r = 0; $r -lt $HEART_ROWS; $r++) {
    $line = $heart[$r]
    for ($x = 0; $x -lt $W; $x++) {
      $a = $on[$x, (2 * $r)]; $b = $on[$x, (2 * $r + 1)]
      if (-not $a -and -not $b) { $line += ' '; continue }
      $col = if ($flat) { '1;30' } elseif ($age[$x] -lt $W / 2) { '0;32' } else { '1;30' }
      $ch = if ($a -and $b) { $FULL } elseif ($a) { $UP } else { $LO }
      $line += "$E[$($col)m$ch"
    }
    $line + $N
  }
}

$recent = @(); $jobs = @(); $tasks = @(); $lastRead = -1
function Read-State([long]$now) {
  $script:jobs = @(Get-ChildItem "$state\jobs" -File | ForEach-Object {
    if (-not (Get-Process -Id ([int]$_.Name))) { Remove-Item $_.FullName; return }
    $st, $label = (Get-Content -Raw $_.FullName).Trim() -split '\|', 2
    [pscustomobject]@{ start = [long]$st; label = $label }
  })
  $script:tasks = @(Get-ChildItem "$state\tasks" -File | ForEach-Object { (Get-Content -Raw $_.FullName).Trim() })
  $script:recent = @(Get-Content "$state\log" -Tail 5 | Where-Object { $_ -match '^\d+\|' })
}

function Draw([int]$frame, [int]$rows, [int]$cols) {
  $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  $top = New-Object System.Collections.Generic.List[string]
  $add = { param($s) $top.Add("  $s$N") }

  & $add ''
  & $add "$B${CYN}PcRescue$N$B  checked from the laptop over the network cable$N   $(Get-Date -Format 'HH:mm:ss')"
  & $add "$DIM$(Repeat '-' 72)"
  & $add ''
  foreach ($j in $jobs) { & $add "$(BusyAnim $frame)  $B${YEL}WORKING$N  $B$($j.label)$N  $DIM$(Clock ($now - $j.start))" }
  if ($jobs.Count -eq 0) {
    $ago = ''
    if ($recent.Count -gt 0) {
      $t = $now - [long]($recent[-1] -split '\|')[0]
      $ago = if ($t -lt 60) { " (last one ${t}s ago)" } else { " (last one $([math]::Floor($t / 60)) min ago)" }
    }
    & $add "$(IdleAnim $frame)  ${GRN}READY$N    waiting for the next command from the laptop$DIM$ago"
  }

  if ($tasks.Count -gt 0) {
    & $add ''; & $add "${B}Long tasks$N"
    foreach ($t in $tasks) {
      $tl, $tp, $td = $t -split '\|', 3
      $pct = 0; [void][int]::TryParse(($tp -split '\.')[0], [ref]$pct); $pct = [math]::Min(100, [math]::Max(0, $pct))
      $fill = [math]::Floor($pct * 40 / 100)
      & $add "  $tl"
      & $add "  $GRN[$(Repeat '#' $fill)$N$DIM$(Repeat '.' (40 - $fill))$N$GRN]$N $B$pct%$N  $td"
    }
  }

  & $add ''
  $pcRow = $top.Count
  & $add "${B}This PC$N"
  if ($S.ready) {
    & $add "  Windows up for   $B$(LongClock $S.up)$N   ${DIM}(starts again from 0 if this PC crashes)"
    $c = $GRN; if ($S.load -ge 70) { $c = $YEL }; if ($S.load -ge 90) { $c = $RED }
    & $add "  CPU              ${c}load $($S.load)%$N"
    & $add "  Memory           $(Size $S.memUsed) used of $(Size $S.memTotal)"
    if ($S.netUp) {
      & $add "  Network cable    ${GRN}connected$N, $($S.speed)   out $(Size $S.tx)/s   in $(Size $S.rx)/s"
    } else {
      & $add "  Network cable    ${RED}not connected$N - check the cable to the laptop"
    }
    $who = if ($S.laptop) { "${GRN}laptop connected$N" } else { "${DIM}waiting for the laptop$N" }
    $addr = if ($S.address) { "address $B$($S.address)$N" } else { "${YEL}no cable address yet$N" }
    & $add "  Remote access    $addr   $who"
    $first = '  Drives           '
    foreach ($d in $S.drives) {
      # Only the drive's own SMART verdict says "healthy"; Windows' health often stays Healthy on a dying drive.
      $verdict = if ($d.failing -eq $true) { "$B${RED}drive reports FAILING$N" }
        elseif ($d.failing -eq $false -and $d.health -eq 'Healthy') { "${GRN}healthy$N" }
        elseif ($d.failing -eq $false) { "$YEL$($d.health)$N" }
        else { "${DIM}no SMART reading$N" }
      # Pad with PadRight, not -f: names may contain braces.
      & $add ("$first$($d.letter):  " + (Size $d.size).PadRight(9) + ' ' + "$(Size $d.free) free".PadRight(12) + ' ' + "$($d.model)".PadRight(18) + " $verdict")
      $first = '                   '
    }
  } else {
    & $add "  ${DIM}reading this PC...$N"
  }

  # The heart, in the empty space to the right of the This PC panel.
  $w = $cols - $HEART_COL - 13 - 3
  if ($w -ge 8) {
    if ($w -gt 30) { $w = 30 }
    $img = @(Picture $frame $w (-not $S.netUp))
    for ($i = 0; $i -lt $img.Count -and $pcRow + $i -lt $top.Count; $i++) {
      $pad = [math]::Max(1, $HEART_COL - 1 - (Plain $top[$pcRow + $i]).Length)
      $top[$pcRow + $i] += (Repeat ' ' $pad) + $img[$i]
    }
  }

  if ($S.copying) {
    & $add ''
    & $add "$B${CYN}Copying with the laptop$N  out $(Size $S.tx)/s   in $(Size $S.rx)/s"
  }

  $bottom = @(
    "  $N",
    "  ${DIM}Nothing on this PC's drives is changed without your OK in the laptop chat.$N",
    "  ${DIM}Keep this window open. Closing it doesn't stop remote access; reopen it with ""2 - Status screen"" on the stick.$N"
  )

  # As many recent commands as the screen has room for.
  $room = [math]::Min($rows - 1 - $top.Count - $bottom.Count - 2, $recent.Count)
  if ($room -gt 0) {
    & $add ''
    & $add "${B}Recent commands from the laptop$N"
    for ($i = $recent.Count - $room; $i -lt $recent.Count; $i++) {
      $et, $res, $secs, $lb = $recent[$i] -split '\|', 4
      $hh = [DateTimeOffset]::FromUnixTimeSeconds([long]$et).ToLocalTime().ToString('HH:mm')
      $padRes = "$res".PadRight(8)
      $padRes = if ($res -eq 'done') { "$GRN$padRes$N" } else { "$YEL$padRes$N" }
      & $add ("  $DIM$hh$N  $padRes " + (Clock ([int]$secs)).PadLeft(6) + "  $lb")
    }
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("$E[H")
  foreach ($l in @($top) + $bottom) { [void]$sb.Append("$l$E[K`n") }
  [void]$sb.Append("$E[J")
  $sb.ToString()
}

$frame = 0
try {
  while ($true) {
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($now -ne $lastRead) { Read-State $now; $lastRead = $now }
    if ($test) {
      $text = Draw $frame 33 120
      if ($frame -eq $Frames - 1) { (Plain $text) -replace "`n$", '' }
      $frame++
      if ($frame -ge $Frames) { break }
      continue
    }
    $rows = [Console]::WindowHeight; $cols = [Console]::WindowWidth
    [Console]::Write((Draw $frame $rows $cols))
    $frame++
    Start-Sleep -Milliseconds 100
  }
} finally {
  if (-not $test) { [Console]::Write("$E[0m$E[?7h$E[2J"); [Console]::CursorVisible = $true }
}
