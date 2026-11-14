#!/bin/bash
# PcRescue status screen for the faulty PC's own monitor.
#
# Draws on a console of its own (tty8) and switches the monitor to it, so whoever sits at
# this PC can see that the laptop is working on it: what it is doing right now, long tasks
# with a progress bar, how long Linux has stayed up, temperature and load, memory, the
# cable, which drives are mounted and whether they are read-only, files being copied to
# the laptop, and the last commands. Alt+F1 goes to the command line, Alt+F8 comes back here.
#
# Beside the "This PC" panel a small heart pulses calmly next to a slow ECG line while the
# cable is connected, and turns grey and flat when it isn't. It is meant to be seen out of
# the corner of an eye: no flashing, no bright colours, the same pace all the time. It sits
# in empty space, so every panel keeps its place.
#
# Apart from removing stale job files it only reads. Inputs:
#   /run/pcrescue/jobs/<pid>    start-epoch|label         while a scripts/pc.ps1 command runs
#   /run/pcrescue/log           end-epoch|result|seconds|label   one line per finished command
#   /run/pcrescue/tasks/<name>  label|percent|detail      long background work (pcrescue-readtest);
#                               the task rewrites this file as it goes and deletes it when done
# Started at boot by autorun/autorun, or by scripts/install-status-screen.ps1, as the
# systemd unit pcrescue-status.

shopt -s extglob
export TERM=linux LC_ALL=C
TTY=${PCRESCUE_TTY:-/dev/tty8}
STATE=/run/pcrescue
mkdir -p "$STATE/jobs" "$STATE/tasks"
touch "$STATE/log"

exec >"$TTY" 2>/dev/null || exit 1
stty -echo <"$TTY"
setterm --blank 0 --powerdown 0 --cursor off
# 16x32 font: 120x33 on a 1080p monitor, readable from across the room, and its half-block
# characters make square 16x16 pixels for the heart.
setfont -C "$TTY" latarcyrheb-sun32 2>/dev/null
printf '\033[0m\033[?7l\033[2J' # no line wrap: long lines are cut instead of scrolling the screen
chvt "${TTY#/dev/tty}"
trap 'printf "\033[0m\033[?7h\033[?25h\033[2J"; stty echo <"$TTY"; exit 0' TERM INT HUP

E=$'\033'
N="$E[0m"; B="$E[1m"; DIM="$E[2m"
RED="$E[31m"; GRN="$E[32m"; YEL="$E[33m"; CYN="$E[36m"
SPIN='|/-\'

# The heart: two hand-drawn 13x12 pixel frames, resting and one pixel bigger all round on
# the beat, in dark red with a bright red highlight. Each text cell holds two pixels, one
# above the other, drawn with half-block characters; a cell holding highlight and heart
# uses the highlight as foreground and the heart's red as background. Beside it, an ECG
# line written one column per frame, green near the pen and grey further back.
# One beat every 12 frames (1.2 s, 50 per minute); the R spike lines up with the beat.
HEART_COL=80  # screen column where the picture starts, right of the This PC panel's text
HEART_ROWS=6  # text rows, 12 pixels
read -r -d '' HEART_AWK <<'AWK'
function fg(ch) { return flat ? "1;30" : (ch == "o" ? "1;31" : "31") }
function cell(t, b) {
  if (t == "." && b == ".") return E "[0m "
  if (b == ".") return E "[0;" fg(t) "m" UP
  if (t == ".") return E "[0;" fg(b) "m" LO
  if (t == b || flat) return E "[0;" fg(t) "m" FULL
  return E "[0;1;31;41m" (t == "o" ? UP : LO)
}
BEGIN {
  UP = "\342\226\200"; LO = "\342\226\204"; FULL = "\342\226\210"; E = "\033"
  rest[0] = "............."; big[0] = "..XXX...XXX.."
  rest[1] = "...XX...XX..."; big[1] = ".XooXX.XXXXX."
  rest[2] = "..XooX.XXXX.."; big[2] = "XoXXXXXXXXXXX"
  rest[3] = ".XoXXXXXXXXX."; big[3] = "XXXXXXXXXXXXX"
  rest[4] = ".XXXXXXXXXXX."; big[4] = "XXXXXXXXXXXXX"
  rest[5] = "..XXXXXXXXX.."; big[5] = ".XXXXXXXXXXX."
  rest[6] = "...XXXXXXX..."; big[6] = "..XXXXXXXXX.."
  rest[7] = "....XXXXX...."; big[7] = "...XXXXXXX..."
  rest[8] = ".....XXX....."; big[8] = "....XXXXX...."
  rest[9] = "......X......"; big[9] = ".....XXX....."
  rest[10] = "............."; big[10] = "......X......"
  rest[11] = "............."; big[11] = "............."
  P = 12
  beat = !flat && (T % P) < 2
  for (r = 0; r < 12; r++) heart[r] = beat ? big[r] : rest[r]

  # ECG: R spike, S dip, T wave, P wave over one 12-column beat.
  split("5 -1 0 0 1 2 1 0 0 0 1 0", wave, " ")
  H = rows * 2; base = H - 4; gap = 3
  pen = T % W
  for (x = 0; x < W; x++) {
    age[x] = pen - x; if (age[x] < 0) age[x] += W
    if (age[x] > W - gap || T - age[x] < 0) { y[x] = -1; continue }
    y[x] = base - (flat ? 0 : wave[(T - age[x]) % P + 1])
  }
  for (x = 0; x < W; x++) {
    if (y[x] < 0) continue
    on[x, y[x]] = 1
    if (x > 0 && y[x - 1] >= 0) {
      if (y[x - 1] < y[x]) { for (k = y[x - 1] + 1; k < y[x]; k++) on[x, k] = 1 }
      else { for (k = y[x] + 1; k < y[x - 1]; k++) on[x, k] = 1 }
    }
  }

  for (r = 0; r < rows; r++) {
    line = ""
    for (c = 1; c <= 13; c++) line = line cell(substr(heart[2 * r], c, 1), substr(heart[2 * r + 1], c, 1))
    line = line E "[0m   "
    for (x = 0; x < W; x++) {
      a = on[x, 2 * r]; b = on[x, 2 * r + 1]
      if (!a && !b) { line = line " "; continue }
      col = flat ? "1;30" : (age[x] < W / 2 ? "0;32" : "1;30")
      line = line E "[" col "m" (a && b ? FULL : (a ? UP : LO))
    }
    print line E "[0m"
  }
}
AWK

net_dev=$(ls /sys/class/net | grep -E '^(en|eth)' | head -n 1)
temp_dir=
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name")" = coretemp ] && temp_dir=$h
done
if [ -z "$temp_dir" ]; then
  for h in /sys/class/hwmon/hwmon*; do [ -e "$h/temp1_input" ] && { temp_dir=$h; break; }; done
fi

repeat() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
clock() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }
long_clock() { printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }
size() {
  if [ "$1" -ge 1073741824 ]; then printf '%d.%d GB' $(($1 / 1073741824)) $(($1 % 1073741824 * 10 / 1073741824))
  elif [ "$1" -ge 1048576 ]; then printf '%d MB' $(($1 / 1048576))
  else printf '%d KB' $(($1 / 1024)); fi
}

# A block bouncing in a track while the laptop is running something.
busy_anim() {
  local w=20 b=4 span pos
  span=$((w - b)); pos=$(((frame / 2) % (2 * span)))
  [ "$pos" -gt "$span" ] && pos=$((2 * span - pos))
  printf '%s[%s%s%s%s%s] %s' "$CYN" "$(repeat ' ' "$pos")" "$B" "$(repeat '#' "$b")" "$N$CYN" \
    "$(repeat ' ' $((w - b - pos)))" "${SPIN:frame/2%4:1}$N"
}
# A slow dot drifting back and forth while waiting; same width as busy_anim.
idle_anim() {
  local w=20 pos
  pos=$(((frame / 4) % (2 * (w - 1))))
  [ "$pos" -gt $((w - 1)) ] && pos=$((2 * (w - 1) - pos))
  printf '%s[%s.%s]  %s' "$DIM" "$(repeat ' ' "$pos")" "$(repeat ' ' $((w - 1 - pos)))" "$N"
}

tx_last=; rx_last=; t_last=0; tx_rate=0; rx_rate=0; copy_file=; copy_seen=0; rows=33; cols=120
sample() {
  local now=$1 t=0 v f k n p fd target found= sz
  read -r up _ </proc/uptime; up=${up%.*}
  read -r load _ </proc/loadavg
  temp=
  if [ -n "$temp_dir" ]; then
    for f in "$temp_dir"/temp*_input; do read -r v <"$f" && [ "$v" -gt "$t" ] && t=$v; done
    temp=$((t / 1000))
  fi
  while read -r k v _; do
    case $k in MemTotal:) mem_total=$v ;; MemAvailable:) mem_avail=$v ;; esac
  done </proc/meminfo
  carrier=0; speed=?
  if [ -n "$net_dev" ]; then
    n=/sys/class/net/$net_dev
    read -r carrier <"$n/carrier" || carrier=0
    read -r speed <"$n/speed" || speed=?
    read -r tx <"$n/statistics/tx_bytes"; read -r rx <"$n/statistics/rx_bytes"
    if [ -n "$tx_last" ] && [ "$now" -gt "$t_last" ]; then
      tx_rate=$(((tx - tx_last) / (now - t_last))); rx_rate=$(((rx - rx_last) / (now - t_last)))
    fi
    tx_last=$tx; rx_last=$rx; t_last=$now
  fi
  mapfile -t mounts < <(awk '$1 ~ /^\/dev\/(sd|nvme|mmcblk|vd)/ && $2 !~ /^\/run\/archiso/ { split($4, o, ","); print o[1], $1, $2 }' /proc/mounts)
  # A copy to the laptop shows up as a file held open by sftp-server (or by scp -f).
  for p in $(pgrep -x sftp-server; pgrep -x scp); do
    for fd in /proc/"$p"/fd/*; do
      target=$(readlink "$fd") || continue
      case $target in /dev/* | /proc/* | /sys/* | socket:* | pipe:* | anon_inode:*) continue ;; esac
      [ -f "$target" ] && found=$target
    done
  done
  if [ -n "$found" ]; then copy_file=$found; copy_seen=$now
  elif [ $((now - copy_seen)) -gt 3 ]; then copy_file=; fi
  mapfile -t recent < <(tail -n 5 "$STATE/log")
  sz=$(stty size <"$TTY" 2>/dev/null)
  if [[ $sz =~ ^([0-9]+)\ ([0-9]+)$ ]]; then rows=${BASH_REMATCH[1]}; cols=${BASH_REMATCH[2]}; fi
}

draw() {
  local now=$1 j pid st label t tl tp td m first mode c f et res secs lb pad hh ago= room i w pc_row plain l out
  local -a top=() bottom=() img=()
  add() { top+=("  $1$N"); }

  add ""
  add "$B${CYN}PcRescue$N$B  checked from the laptop over the network cable$N   $(printf '%(%H:%M:%S)T' -1)"
  add "$DIM$(repeat - 72)"
  add ""

  for j in "$STATE"/jobs/*; do
    [ -e "$j" ] || continue
    pid=${j##*/}
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$j"; continue; fi
    IFS='|' read -r st label <"$j"
    add "$(busy_anim)  $B${YEL}WORKING$N  $B$label$N  $DIM$(clock $((now - st)))"
    t=busy
  done
  if [ "$t" != busy ]; then
    if [ ${#recent[@]} -gt 0 ]; then
      IFS='|' read -r et _ <<<"${recent[-1]}"
      t=$((now - et))
      if [ "$t" -lt 60 ]; then ago=" (last one ${t}s ago)"; else ago=" (last one $((t / 60)) min ago)"; fi
    fi
    add "$(idle_anim)  ${GRN}READY$N    waiting for the next command from the laptop$DIM$ago"
  fi

  local have_tasks=0
  for t in "$STATE"/tasks/*; do
    [ -f "$t" ] || continue
    IFS='|' read -r tl tp td <"$t"
    tp=${tp%%.*}; [[ $tp =~ ^[0-9]+$ ]] || tp=0; [ "$tp" -gt 100 ] && tp=100
    [ "$have_tasks" -eq 0 ] && { add ""; add "${B}Long tasks$N"; have_tasks=1; }
    add "  $tl"
    add "  $GRN[$(repeat '#' $((tp * 40 / 100)))$N$DIM$(repeat '.' $((40 - tp * 40 / 100)))$N$GRN]$N $B$tp%$N  $td"
  done

  add ""
  pc_row=${#top[@]}
  add "${B}This PC$N"
  add "  Linux up for     $B$(long_clock "$up")$N   ${DIM}(starts again from 0 if this PC crashes)"
  c=
  if [ -n "$temp" ]; then
    c=$GRN; [ "$temp" -ge 70 ] && c=$YEL; [ "$temp" -ge 85 ] && c=$RED
    c="$c$temp C$N   "
  fi
  add "  CPU              ${c}load $load"
  add "  Memory           $(size $(((mem_total - mem_avail) * 1024))) used of $(size $((mem_total * 1024)))"
  if [ "$carrier" = 1 ]; then
    add "  Network cable    ${GRN}connected$N, $speed Mb/s   out $(size "$tx_rate")/s   in $(size "$rx_rate")/s"
  else
    add "  Network cable    ${RED}not connected$N - check the cable to the laptop"
  fi
  # One line per drive: device, folder, read-only or READ-WRITE.
  first="  Drives mounted   "
  if [ ${#mounts[@]} -eq 0 ]; then add "$first${DIM}none"; fi
  for m in "${mounts[@]}"; do
    set -- $m
    if [ "$1" = ro ]; then mode="${GRN}read-only$N"; else mode="$B${RED}READ-WRITE$N"; fi
    [ -b "$2" ] || mode="$mode  ${YEL}(drive gone)$N"
    add "$first$(printf '%-6s' "${2#/dev/}") at $(printf '%-12s' "$3") $mode"
    first="                   "
  done

  # The heart, in the empty space to the right of the This PC panel.
  w=$((cols - HEART_COL - 13 - 3))
  if [ "$w" -ge 8 ]; then
    [ "$w" -gt 30 ] && w=30
    mapfile -t img < <(awk -v T="$frame" -v W="$w" -v rows="$HEART_ROWS" -v flat=$((carrier != 1)) "$HEART_AWK")
    for ((i = 0; i < ${#img[@]} && pc_row + i < ${#top[@]}; i++)); do
      plain=${top[pc_row + i]//$E\[*([0-9;])m/}
      pad=$((HEART_COL - 1 - ${#plain})); [ "$pad" -lt 1 ] && pad=1
      top[pc_row + i]+="$(repeat ' ' "$pad")${img[i]}"
    done
  fi

  if [ -n "$copy_file" ]; then
    f=$copy_file; [ ${#f} -gt 56 ] && f="...${f: -53}"
    add ""
    add "$B${CYN}Copying to the laptop$N  $f  $(size "$tx_rate")/s"
  fi

  bottom+=("  $N")
  bottom+=("  ${DIM}Nothing on this PC's drives is changed without your OK in the laptop chat.$N")
  bottom+=("  ${DIM}Alt+F1: command line    Alt+F8: this screen$N")

  # As many recent commands as the screen has room for.
  room=$((rows - 1 - ${#top[@]} - ${#bottom[@]} - 2))
  [ "$room" -gt ${#recent[@]} ] && room=${#recent[@]}
  if [ "$room" -gt 0 ]; then
    add ""
    add "${B}Recent commands from the laptop$N"
    for ((i = ${#recent[@]} - room; i < ${#recent[@]}; i++)); do
      IFS='|' read -r et res secs lb <<<"${recent[i]}"
      printf -v hh '%(%H:%M)T' "$et"
      printf -v pad '%-8s' "$res"
      if [ "$res" = done ]; then pad="$GRN$pad$N"; else pad="$YEL$pad$N"; fi
      add "  $DIM$hh$N  $pad $(printf '%6s' "$(clock "$secs")")  $lb"
    done
  fi

  out="$E[H"
  for l in "${top[@]}" "${bottom[@]}"; do out+="$l$E[K"$'\n'; done
  printf '%s' "$out$E[J"
}

frame=0; last=0
while :; do
  printf -v now '%(%s)T' -1
  if [ "$now" != "$last" ]; then sample "$now"; last=$now; fi
  draw "$now"
  frame=$((frame + 1))
  sleep 0.1
done
