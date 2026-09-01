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
