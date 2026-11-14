<#
  PcRescue: runs one command sent by scripts\win.ps1 and records it for the status screen
  (status.ps1), the Windows counterpart of pcrescue-job on SystemRescue. While it runs the
  screen shows WORKING; afterwards it is listed under recent commands. The exit code is
  passed through.

  Installed into C:\ProgramData\PcRescue by "1 - Start remote access".
  -Label and -Script are base64 (UTF-8); -ScriptFile is a script copied over by win.ps1 for
  commands too long for one command line.

  Records (the same formats as the SystemRescue screen):
    status\jobs\<pid>   start-epoch|label                   while the command runs
    status\log          end-epoch|result|seconds|label      one line per finished command
#>
param([string]$Label, [string]$Script, [string]$ScriptFile)

$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$state = Join-Path $env:ProgramData 'PcRescue\status'

if ($ScriptFile) {
  $text = [IO.File]::ReadAllText($ScriptFile)
  Remove-Item -LiteralPath $ScriptFile -ErrorAction SilentlyContinue
} else {
  $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Script))
}
$name = ''
if ($Label) { $name = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Label)) }
$name = ($name -replace '[\r\n|]', ' ').Trim()
if ($name.Length -gt 70) { $name = $name.Substring(0, 67) + '...' }

# Run the command as a script file: "exit 3" then returns here with $LASTEXITCODE = 3.
$tmp = Join-Path $env:TEMP ('pcrescue-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $true))

$start = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$jobFile = Join-Path $state "jobs\$PID"
try {
  New-Item -ItemType Directory -Force (Split-Path $jobFile) | Out-Null
  [IO.File]::WriteAllText($jobFile, "$start|$name")
} catch { }

$global:LASTEXITCODE = 0
$code = 0
try {
  & $tmp
  if ($LASTEXITCODE) { $code = $LASTEXITCODE }
} catch {
  Write-Error $_
  $code = 1
} finally {
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $jobFile -ErrorAction SilentlyContinue
  $end = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  $result = if ($code -eq 0) { 'done' } else { "exit $code" }
  try { [IO.File]::AppendAllText((Join-Path $state 'log'), "$end|$result|$($end - $start)|$name`r`n") } catch { }
}
exit $code
