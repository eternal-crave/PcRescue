#!/bin/bash
# Reads a whole disk once, read-only, to find areas that fail or answer slowly.
# Usage, in the background so a dropped SSH session doesn't stop it:
#   systemd-run --unit=pcrescue-readtest-sdc --collect /usr/local/bin/pcrescue-readtest /dev/sdc
# Never writes to the disk: dd reads it with O_DIRECT and throws the data away.
# Progress shows on the status screen. Results: /root/readtest-<disk>.log, one line per
# 1 GiB step: "<GiB from the start> <milliseconds> ok|ERROR", then a summary line.
# Skip this on a hard disk with SMART failure signs: offer the backup first.

dev=${1:?usage: pcrescue-readtest /dev/sdX}
name=${dev##*/}
[ -b "$dev" ] || { echo "$dev is not a block device"; exit 2; }

state=/run/pcrescue
mkdir -p "$state/tasks"
task=$state/tasks/readtest-$name
log=/root/readtest-$name.log
model=$(lsblk -dno MODEL "$dev" | sed 's/ *$//')
total=$(($(blockdev --getsize64 "$dev") / 1048576)) # MiB
step=1024
label="Read test of $name ($model), read-only"
start=$(date +%s)
pos=0; errors=0; slowest=0; slowest_at=0
: >"$log"
trap 'rm -f "$task"' EXIT

while [ "$pos" -lt "$total" ]; do
  n=$step; [ $((pos + n)) -gt "$total" ] && n=$((total - pos))
  t0=$(date +%s%N)
  if dd if="$dev" of=/dev/null bs=1M skip="$pos" count="$n" iflag=direct status=none 2>/dev/null; then
    r=ok
  else
    r=ERROR; errors=$((errors + 1))
  fi
  ms=$((($(date +%s%N) - t0) / 1000000))
  echo "$((pos / 1024)) $ms $r" >>"$log"
  [ "$ms" -gt "$slowest" ] && { slowest=$ms; slowest_at=$((pos / 1024)); }
  pos=$((pos + n))
  elapsed=$(($(date +%s) - start)); [ "$elapsed" -gt 0 ] || elapsed=1
  printf '%s|%d|%d of %d GB, %d MB/s, %d errors, slowest GB %d.%d s (at GB %d)\n' \
    "$label" $((pos * 100 / total)) $((pos / 1024)) $((total / 1024)) $((pos / elapsed)) \
    "$errors" $((slowest / 1000)) $((slowest % 1000 / 100)) "$slowest_at" >"$task"
done

end=$(date +%s)
summary="Read test of $name: $errors errors, slowest GB $((slowest / 1000)).$((slowest % 1000 / 100)) s at GB $slowest_at"
echo "SUMMARY $summary, $((end - start)) s" >>"$log"
printf '%s|%s|%s|%s\n' "$end" "done" "$((end - start))" "$summary" >>"$state/log"
