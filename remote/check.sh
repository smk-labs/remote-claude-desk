#!/usr/bin/env bash
# Every server-side precondition desk-doctor checks, in one round trip.
#
# Run on the server by desk_remote_run, with MIN, ADDR and PORT in the
# environment. Emits one "STATUS<tab>TEXT" line per result; desk-doctor parses
# them back into the same verbs it prints locally.
#
# One script and one round trip on purpose: twenty separate ssh calls take
# twenty round trips, which is most of a minute on a slow link.
# The wire format, one line per result: STATUS<tab>TEXT. desk-doctor parses it
# back into the same four verbs it uses locally, so a check reads the same
# whichever side of the connection it runs on.
p() { printf '%s\t%s\n' "$1" "$2"; }
f() { printf 'fix\t%s\n' "$1"; }
me="$(id -un)"

# xrdp itself
if systemctl is-active --quiet xrdp 2>/dev/null; then p ok "xrdp is running"
else p bad "xrdp is not running"; f "sudo systemctl start xrdp"; fi

# Can this account log in at all.
#
# The precondition that guarantees failure while every other check is green.
# An account made with `adduser --disabled-password` has no password, and xrdp
# refuses it whatever is typed. What you see is FreeRDP's own credentials box,
# which reappears on each attempt and says nothing about why, so it reads as a
# wrong password rather than as an account that cannot accept one.
#
# `passwd -S` prints one status letter: P has a usable password, L is locked,
# NP has none at all. Only P can log in.
locked="$(passwd -S "$me" 2>/dev/null | awk '{print $2}')"
case "$locked" in
  P)  p ok "$me has a password, so xrdp can accept a login" ;;
  L)  p bad "$me is locked (passwd -S says L), so every RDP login fails whatever you type"
      f "on the server: sudo passwd $me" ;;
  NP) p bad "$me has no password at all (passwd -S says NP), so xrdp will refuse it"
      f "on the server: sudo passwd $me" ;;
  # Not every box lets an unprivileged user read this, and a check that cannot
  # read its input has learned nothing rather than found a problem.
  *)  p note "could not read whether $me has a password (passwd -S said '${locked:-nothing}')" ;;
esac

if systemctl is-active --quiet xrdp-sesman 2>/dev/null; then p ok "xrdp-sesman is running"
else p bad "xrdp-sesman is not running"; fi

# The listener. Ubuntu's default is 0.0.0.0:3389, which on a box with no
# firewall means the desktop is exposed to the internet.
listen="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -c "^${ADDR}:${PORT}$")"
if [ "${listen:-0}" -ge 1 ]; then p ok "xrdp is listening on ${ADDR}:${PORT}"
else
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ':3389$'; then
    p bad "xrdp is on the default 0.0.0.0:3389, not ${ADDR}:${PORT}, so it is exposed"; f "run server/install.sh to move the listener onto loopback"
  else
    p bad "nothing is listening on ${ADDR}:${PORT}"; f "run server/install.sh on the server"
  fi
fi

# The single most common cause of early failures: Ubuntu ships the xrdp user
# outside the ssl-cert group, so it cannot read its own TLS key.
if sudo -n -u xrdp test -r /etc/xrdp/key.pem 2>/dev/null; then
  p ok "the xrdp user can read its TLS key"
elif id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -qx ssl-cert; then
  p ok "the xrdp user is in the ssl-cert group"
else
  p bad "the xrdp user is NOT in ssl-cert, so TLS connections fail"; f "sudo usermod -aG ssl-cert xrdp && sudo systemctl restart xrdp"
fi

# Session policy. UBI reuses a session for the same user, depth and client IP.
grep -qs '^Policy=UBI' /etc/xrdp/sesman.ini \
  && p ok "sesman Policy=UBI, so reconnecting returns to the same session" \
  || p warn "sesman Policy is not UBI, so a reconnect may start a second session"

off="$(awk -F= '/^X11DisplayOffset/{print $2}' /etc/xrdp/sesman.ini 2>/dev/null | tr -d ' ')"
if [ -n "$off" ] && [ "$off" -ge "$MIN" ] 2>/dev/null; then
  p ok "X11DisplayOffset=$off, clear of the other tenants"
else
  p warn "X11DisplayOffset is '${off:-unset}' but DESK_DISPLAY_MIN is $MIN"
fi

# The orphan reaper.
if [ -x /usr/local/sbin/xrdp-reap-orphans ]; then
  p ok "the orphan reaper is installed"
else
  p warn "no orphan reaper, so a sesman restart will strand your session"
  f "run server/install.sh"
fi

# Tools the bridge and the layout push need on the far side. Written as if/else
# and not as `A && B || C`, because a `fix` line appended to that form runs
# whichever way the test went, and hints then print under passing checks.
need() { # need <command> <severity> <note-when-ok> <consequence> [fix]
  if command -v "$1" >/dev/null 2>&1; then
    p ok "$1 present${3:+ ($3)}"
  else
    p "$2" "$1 is missing, so $4"
    if [ -n "${5:-}" ]; then f "$5"; fi
  fi
}
need xclip     bad  "the clipboard bridge needs it" "text cannot cross"          "sudo apt install xclip"
need setxkbmap bad  ""                              "the keyboard layout cannot be set" "sudo apt install x11-xkb-utils"
need xmodmap   warn ""                              "the Fn fallback route is unavailable"
need python3   bad  ""                              "the clipboard agent cannot run"    "sudo apt install python3"

# Orphaned sessions: an X server older than the sesman that is meant to track
# it. This is the ERRINFO_LOGOFF_BY_USER failure, and it is invisible otherwise.
sesman_started=$(date -d "$(systemctl show xrdp-sesman -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)
orphans=0 live=0
for pid in $(pgrep -u "$me" -x Xorg 2>/dev/null); do
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'xrdp/xorg.conf' || continue
  live=$((live+1))
  started=$(date -d "$(ps -o lstart= -p "$pid")" +%s 2>/dev/null || echo 0)
  [ "$sesman_started" -gt 0 ] && [ "$started" -gt 0 ] && [ "$started" -lt "$sesman_started" ] \
    && orphans=$((orphans+1))
done
if [ "$orphans" -gt 0 ]; then
  p bad "$orphans session(s) predate sesman and are orphaned, so every connect will die at once"; f "desk heals this automatically on the next run"
elif [ "$live" -gt 0 ]; then
  p ok "$live live session(s), all tracked by the current sesman"
else
  p ok "no session running yet (desk will start one)"
fi

# Which display, and is it ours. Other tenants running Xvfb with -ac have
# access control off, so attaching to one means opening on a stranger's screen.
found=""
for pid in $(pgrep -u "$me" -x Xorg 2>/dev/null); do
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
  case "$cmd" in *xrdp/xorg.conf*) ;; *) continue ;; esac
  for tok in $cmd; do case "$tok" in :[0-9]*) found="${tok#:}"; break ;; esac; done
  [ -n "$found" ] && break
done
if [ -n "$found" ]; then
  if [ "$found" -lt "$MIN" ]; then
    p bad "the session is on :$found, below the floor of :$MIN"
  elif [ "$(stat -c %U "/tmp/.X11-unix/X$found" 2>/dev/null)" != "$me" ]; then
    p bad "display :$found is not owned by $me; refusing to touch it"
  else
    p ok "session display is :$found, owned by $me"
  fi
fi

# Foreign displays, for context only.
foreign=0
for s in /tmp/.X11-unix/X*; do
  [ -S "$s" ] || continue
  [ "$(stat -c %U "$s" 2>/dev/null)" = "$me" ] || foreign=$((foreign+1))
done
[ "$foreign" -gt 0 ] && p note "$foreign X display(s) belong to other users on this box"

# ─── headroom: can this box actually draw the desktop it is being asked for ───
#
# Every check above can be green on a machine that is unusable, and that is not
# a hypothetical. On the box this was written against: xrdp running, sesman
# tracking one live session, the listener on loopback, the ssl-cert group right,
# 31 green lines. And one hung claude-desktop process holding an entire core for
# eight hours, on a box that has two.
#
# What that felt like from the Mac was not "the server is busy". It was the
# window coming up fine and then the pointer turning into a spinner the moment
# you touched it, with macOS labelling the client Not Responding. Nothing in the
# client says the far side ran out of CPU, so the fault points at the wrong
# machine, which is the exact failure mode this file exists to prevent.
#
# So: three numbers nobody would think to look up by hand.

cores="$(nproc 2>/dev/null || echo 0)"

# A process that has averaged most of a core over its whole life.
#
# `ps` reports pcpu as an average over the process's lifetime, not an instant,
# and that is what makes it usable here rather than noisy: a compile spiking to
# 100% for a minute never reaches this, while something wedged since breakfast
# does.
#
# The five-minute floor is not tidiness. Without it the top row was the `ps`
# that this check runs, at 100% of its own two-millisecond life, and the check
# reported the machine as hung every single time. Same shape as the bracket in
# desk_remote_pkill: a check that reads the process list has to leave itself
# out of it, and here age does that for free, because nothing that matters here
# is under five minutes old.
hog="$(ps -eo pcpu=,etimes=,comm= --sort=-pcpu 2>/dev/null \
        | awk '$2 >= 300 { printf "%d %d %s", $1, $2, $3; exit }')"
hog_cpu="${hog%% *}"
case "$hog_cpu" in ''|*[!0-9]*) hog_cpu=0 ;; esac

if [ "$hog_cpu" -ge 80 ] && [ "$cores" -gt 0 ]; then
  rest="${hog#* }"
  hog_hours=$(( ${rest%% *} / 3600 ))
  p bad "'${hog##* }' has averaged ${hog_cpu}% of a core for ${hog_hours}h, and this box has $cores"
  f "that is a hung process, not load. Log in to the server and end it."
elif [ "$cores" -gt 0 ]; then
  p ok "$cores core(s), nothing holding one permanently"
fi

# Memory, including swap. A desktop that has started swapping stutters in a way
# that reads as a network problem from the other end.
mem_free="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
swap_used="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{if (t>0) print int((t-f)/1024)}' /proc/meminfo 2>/dev/null)"
if [ -n "$mem_free" ] && [ "$mem_free" -lt 400 ]; then
  p bad "only ${mem_free} MB of memory is available, so the desktop will swap and stutter"
  f "close something on the server, or give the box more RAM"
elif [ -n "${swap_used:-}" ] && [ "$swap_used" -gt 100 ]; then
  p warn "${mem_free} MB free, but ${swap_used} MB is already in swap"
elif [ -n "$mem_free" ]; then
  p ok "${mem_free} MB of memory available"
fi

# The framebuffer this connection has asked for, priced in the only currency
# that matters: xrdp encodes every frame in software, on this CPU. Doubling the
# pixels doubles that bill, and the client never mentions it.
#
# The line is 2.4 megapixels, which clears both 1920x1080 and 1920x1200. Above
# that on 2 cores, a scroll in a repainting window queues frames faster than
# they clear, and the input queues behind them.
case "${SIZE:-}" in
  [0-9]*x[0-9]*)
    w="${SIZE%x*}"; h="${SIZE#*x}"
    mpix=$(( w * h / 1000000 ))
    if [ "$cores" -gt 0 ] && [ "$cores" -le 2 ] && [ "$(( w * h ))" -gt 2400000 ]; then
      p warn "DESK_SIZE is ${SIZE} (${mpix} megapixels) and this box has $cores core(s) to encode it"
      f "set DESK_SIZE to 1920x1200 on a 16:10 screen, or 1920x1080 on a 16:9 one"
    else
      p ok "DESK_SIZE ${SIZE} is within what $cores core(s) can encode"
    fi
    ;;
esac

# ─── the two xrdp version traps, both measured on this box ───────────────────
#
# One: scrolling. Before xorgxrdp 0.10 the mouse driver emitted a full wheel
# click for every RDP packet instead of accumulating the delta and emitting one
# per 120 units. A Mac trackpad sends a continuous stream, so a single flick
# arrives as dozens of clicks. Measured here with a passive grab on the root
# window, before the upgrade: 233 events over 5 gestures, median 46 per gesture,
# 138 a second, 7 ms apart. A real wheel sends three to ten. Nothing on the Mac
# can fix it, because the fault is the count and not the size: the macOS scroll
# speed slider and a per-app scroll tool both change the delta, which this
# version of the driver never reads.
xorgxrdp_v="$(dpkg-query -W -f='${Version}' xorgxrdp 2>/dev/null | sed 's/^[0-9]*://')"
case "$xorgxrdp_v" in
  '') ;;
  0.9.*|0.[0-8].*)
    p bad "xorgxrdp $xorgxrdp_v turns every wheel packet into a click, so a trackpad flick scrolls ten times too far"
    f "upgrade to xorgxrdp 0.10 or later, together with xrdp 0.10 or later" ;;
  *) p ok "xorgxrdp $xorgxrdp_v accumulates wheel deltas (trackpad scrolling is sane)" ;;
esac

# Two: the display range. xrdp 0.10 added MaxDisplayNumber, default 63. A server
# set up with a display offset above that gets "X server -- no display in range
# (150 to 63) is available" on every connect, and the client says only "No X
# displays are available", which sounds like the box is full and is not.
if [ -r /etc/xrdp/sesman.ini ]; then
  off="$(awk -F= '/^X11DisplayOffset=/{print $2; exit}' /etc/xrdp/sesman.ini)"
  max="$(awk -F= '/^MaxDisplayNumber=/{print $2; exit}' /etc/xrdp/sesman.ini)"
  case "${off:-}" in
    ''|*[!0-9]*) ;;
    *)
      : "${max:=63}"
      case "$max" in ''|*[!0-9]*) max=63 ;; esac
      if [ "$off" -gt "$max" ]; then
        p bad "X11DisplayOffset=$off is above MaxDisplayNumber=$max, so no session can ever start"
        f "add MaxDisplayNumber=$(( off + 50 )) to [Sessions] in /etc/xrdp/sesman.ini"
      else
        p ok "display range $off to $max, so the offset fits"
      fi ;;
  esac
fi
