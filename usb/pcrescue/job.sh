#!/bin/bash
# Runs one command script sent by scripts/pc.ps1 and records it for the status screen
# (pcrescue-status): shown as WORKING while it runs, then listed under recent commands.
# Usage: pcrescue-job <script-file> [label in base64]
# The exit code of the script is passed through.

f=$1
label=$(printf '%s' "${2:-}" | base64 -d 2>/dev/null | tr -d '\r\n' | tr '|' '/' | cut -c1-70)
[ -n "$label" ] || label=$(grep -m1 -vE '^[[:space:]]*(#|$)' "$f" | tr '|' '/' | cut -c1-70)

state=/run/pcrescue
mkdir -p "$state/jobs"
start=$(date +%s)
printf '%s|%s\n' "$start" "$label" >"$state/jobs/$$"
trap 'rm -f "$state/jobs/$$"' EXIT

bash "$f"
r=$?

end=$(date +%s)
if [ "$r" -eq 0 ]; then result=done; else result="exit $r"; fi
printf '%s|%s|%s|%s\n' "$end" "$result" "$((end - start))" "$label" >>"$state/log"
exit "$r"
