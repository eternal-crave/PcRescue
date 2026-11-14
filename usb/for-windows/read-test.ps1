<#
  PcRescue: read-only surface test of one whole disk on Windows, the counterpart of the
  SystemRescue read test. Reads every sector in 1 MiB steps and never writes. Notes
  unreadable and slow spots, and the drive's SMART counters (reallocated, pending,
  uncorrectable, CRC) before and after.

  Log: C:\ProgramData\PcRescue\read-test-disk<N>.log. The status screen shows the progress
  under long tasks. Start it detached from SSH so it survives a dropped connection:
    Invoke-CimMethod Win32_Process -MethodName Create -Arguments @{ CommandLine =
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PcRescue\read-test.ps1 -Disk 1' }
#>
param([Parameter(Mandatory)][int]$Disk, [int]$SlowMs = 1000)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'PcRescue'
$log = Join-Path $root "read-test-disk$Disk.log"
$task = Join-Path $root "status\tasks\read-test-disk$Disk"
function Log([string]$t) { Add-Content -LiteralPath $log -Value "$((Get-Date).ToString('HH:mm:ss')) $t" }
trap { Log "STOPPED: $($_.Exception.Message)"; Remove-Item -LiteralPath $task -ErrorAction SilentlyContinue; exit 1 }

# SMART raw counters from Windows' copy of the drive's SMART data (512 bytes, 12 per attribute).
function Smart {
  $pnp = (Get-CimInstance Win32_DiskDrive | Where-Object Index -eq $Disk).PNPDeviceID
  $d = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictData -ErrorAction SilentlyContinue |
    Where-Object { ($_.InstanceName -replace '_\d+$', '') -eq $pnp } | Select-Object -First 1
  if (-not $d) { return 'no SMART data' }
  $v = $d.VendorSpecific
  $names = @{ 5 = 'reallocated'; 196 = 'realloc-events'; 197 = 'pending'; 198 = 'uncorrectable'; 199 = 'CRC errors'; 187 = 'reported-uncorrect' }
  $out = foreach ($i in 0..29) {
    $o = 2 + 12 * $i
    if ($names.ContainsKey([int]$v[$o])) {
      $raw = [long]0; for ($b = 5; $b -ge 0; $b--) { $raw = $raw * 256 + $v[$o + 5 + $b] }
      "$($names[[int]$v[$o]])=$raw"
    }
  }
  $out -join ', '
}

Add-Type @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class PcRescueRawDisk {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
}
'@

$info = Get-Disk -Number $Disk
$size = [long]$info.Size
$label = "Reading all of disk $Disk ($($info.FriendlyName))"
Set-Content -LiteralPath $log -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) start: $label, $([math]::Round($size / 1GB, 1)) GB, read-only"
Log "SMART before: $(Smart)"
# GENERIC_READ (0x80000000, written in decimal: PowerShell reads 0x80000000 as a negative
# Int32), share read+write, OPEN_EXISTING. Reads only.
$h = [PcRescueRawDisk]::CreateFile("\\.\PhysicalDrive$Disk", [uint32]2147483648, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h.IsInvalid) { Log "FAILED: cannot open the disk (Windows error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"; exit 1 }
$fs = New-Object IO.FileStream($h, [IO.FileAccess]::Read, 1, $false)

$chunk = [long]1MB; $buf = New-Object byte[] ([int]$chunk)
$pos = [long]0; $bad = 0; $slow = 0; $lastPct = 0   # no 0% line: its speed and time left are meaningless
$sw = New-Object Diagnostics.Stopwatch; $all = [Diagnostics.Stopwatch]::StartNew()
try {
  while ($pos -lt $size) {
    $n = [int][math]::Min($chunk, $size - $pos)
    $sw.Restart()
    try {
      $fs.Position = $pos
      $got = $fs.Read($buf, 0, $n)
      if ($got -ne $n) { throw "short read: $got of $n bytes" }
    } catch {
      $bad++
      Log "UNREADABLE at MiB $([long]($pos / 1MB)) (GB $([math]::Round($pos / 1GB, 1))): $($_.Exception.Message)"
    }
    $ms = $sw.ElapsedMilliseconds
    if ($ms -ge $SlowMs) { $slow++; Log "slow: $ms ms at MiB $([long]($pos / 1MB))" }
    $pos += $n
    $pct = [int][math]::Floor(100 * $pos / $size)
    if ($pct -ne $lastPct) {
      $lastPct = $pct
      $mbs = [math]::Round(($pos / 1MB) / [math]::Max(1, $all.Elapsed.TotalSeconds))
      $left = if ($mbs -gt 0) { [int](($size - $pos) / 1MB / $mbs / 60) } else { 0 }
      Log "progress $pct%  $mbs MB/s average  about $left min left  unreadable $bad  slow $slow"
      [IO.File]::WriteAllText($task, "$label|$pct|$mbs MB/s, about $left min left, unreadable $bad, slow $slow")
    }
  }
  Log "done in $([int]$all.Elapsed.TotalMinutes) min: unreadable $bad, slow $slow"
} catch {
  Log "STOPPED: $($_.Exception.Message)"
} finally {
  $fs.Dispose()
  Log "SMART after: $(Smart)"
  Remove-Item -LiteralPath $task -ErrorAction SilentlyContinue
}
