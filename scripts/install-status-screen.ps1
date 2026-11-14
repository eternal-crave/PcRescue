<#
.SYNOPSIS
  Installs, or refreshes, the PcRescue tools on the running rescue PC from usb\pcrescue:
  the status screen on its monitor (pcrescue-status), the command recorder that scripts\pc.ps1
  uses (pcrescue-job) and the read-only disk read test (pcrescue-readtest).

.DESCRIPTION
  A stick written by scripts\write-usb.ps1 installs these at boot. Run this after editing
  the files in usb\pcrescue, or when the stick was written before they existed, so you don't
  have to rewrite the stick or reboot the PC. It changes nothing on the PC's drives: the
  tools live in the rescue system's memory until it shuts down.
#>
$projectRoot = Split-Path $PSScriptRoot -Parent
$source = Join-Path $projectRoot 'usb\pcrescue'

$lines = New-Object System.Collections.Generic.List[string]
foreach ($tool in @(
    @{ File = 'status.sh'; Name = 'pcrescue-status' },
    @{ File = 'job.sh'; Name = 'pcrescue-job' },
    @{ File = 'readtest.sh'; Name = 'pcrescue-readtest' })) {
  $text = [IO.File]::ReadAllText((Join-Path $source $tool.File)).Replace("`r`n", "`n").TrimEnd("`n")
  if ($text.Contains('PCRESCUE_EOF')) { throw "$($tool.File) contains the heredoc marker PCRESCUE_EOF." }
  $lines.Add("cat > /usr/local/bin/$($tool.Name) <<'PCRESCUE_EOF'")
  $lines.Add($text)
  $lines.Add('PCRESCUE_EOF')
  $lines.Add("chmod 755 /usr/local/bin/$($tool.Name)")
}
$lines.Add(@'
systemctl stop pcrescue-status 2>/dev/null
systemctl reset-failed pcrescue-status 2>/dev/null
systemd-run --unit=pcrescue-status --collect -p Restart=always -p RestartSec=2 /usr/local/bin/pcrescue-status >/dev/null &&
  echo "Status screen is running on the PC's monitor (Alt+F8 there; Alt+F1 for the command line)."
'@)

& (Join-Path $PSScriptRoot 'pc.ps1') -Label 'Installing the status screen' ($lines -join "`n")
exit $LASTEXITCODE
