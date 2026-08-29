#!/usr/bin/env bash
# Kill any xrdp X server that predates the sesman meant to be tracking it.
#
# Run on the server by desk_remote_run, before connecting.
#
# xrdp-sesman keeps its session list in memory. Unattended upgrades restart it,
# and any session running at that moment becomes untracked forever: every later
# connect makes a NEW session, which dies at once because XFCE cannot start
# twice for one user, and takes the client down with it. The symptom is
# ERRINFO_LOGOFF_BY_USER and a client that quits a few seconds in.
#
# A reaper runs as ExecStartPre on xrdp-sesman and normally handles this. This
# is the second line of defence, for a sesman restarted by something that
# bypassed it.
sesman_started=$(date -d "$(systemctl show xrdp-sesman -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || echo 0)
[ "$sesman_started" -gt 0 ] || exit 0
for p in $(pgrep -u "$(id -un)" -x Xorg 2>/dev/null); do
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'xrdp/xorg.conf' || continue
  started=$(date -d "$(ps -o lstart= -p "$p")" +%s 2>/dev/null || echo 0)
  if [ "$started" -gt 0 ] && [ "$started" -lt "$sesman_started" ]; then
    echo "healing: the session on pid $p predates sesman, so it is orphaned" >&2
    kill "$p" 2>/dev/null
  fi
done
sleep 2
exit 0
