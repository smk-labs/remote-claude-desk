#!/usr/bin/env bash
# Undo what install.sh did, on the same box. Config files come back from the
# timestamped backups install.sh made; installed files are removed.
#
# CRITICAL SAFETY RULE, same as install.sh: never restart xrdp-sesman while a
# session is live. sesman keeps its session list in memory, so a session that
# survives a restart is untracked forever. Every later connect then makes a NEW
# session, which dies at once because XFCE cannot start twice for one user.
# This script detects a live session and refuses. Disconnect first, then re-run.
#
# Your data is never deleted. The isolated Claude Desktop root keeps its
# profile, work and logs, and the script prints where it is.

set -euo pipefail

DESK_USER="${SUDO_USER:-$(id -un)}"
DESK_ISOLATED_ROOT=""
WANT_STAMP=""
KEEP_GROUP=0
ASSUME_YES=0

usage() {
  cat <<USAGE
Usage: sudo ./uninstall.sh [options]

  --user NAME            account the install was made for (default: $DESK_USER)
  --isolated-root DIR    isolated Claude Desktop root (default: <user home>/claude-isolated)
  --stamp YYYYmmdd-HHMMSS  restore this backup set (default: the newest one)
  --keep-group           leave user 'xrdp' in group 'ssl-cert'
  --yes                  skip the confirmation prompt
  --help                 print this and exit
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          DESK_USER="${2:?--user needs a value}"; shift 2 ;;
    --isolated-root) DESK_ISOLATED_ROOT="${2:?--isolated-root needs a value}"; shift 2 ;;
    --stamp)         WANT_STAMP="${2:?--stamp needs a value}"; shift 2 ;;
    --keep-group)    KEEP_GROUP=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    --help|-h)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
did()  { printf '   done: %s\n' "$*"; }
skip() { printf '   skip: %s\n' "$*"; }
warn() { printf '   warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  die "Run this as root, or install sudo."
fi

getent passwd "$DESK_USER" >/dev/null || die "No such user: $DESK_USER"
DESK_HOME=$(getent passwd "$DESK_USER" | cut -d: -f6)
[ -n "$DESK_ISOLATED_ROOT" ] || DESK_ISOLATED_ROOT="$DESK_HOME/claude-isolated"

session_live() { pgrep -u "$DESK_USER" -f 'xrdp/xorg.conf' >/dev/null 2>&1; }

# newest_backup <file>; prints the backup path, or nothing if there is none
newest_backup() {
  local f=$1
  if [ -n "$WANT_STAMP" ]; then
    if [ -f "$f.rcd-bak-$WANT_STAMP" ]; then printf '%s\n' "$f.rcd-bak-$WANT_STAMP"; fi
    return 0
  fi
  # The glob sorts lexically and the names are timestamps, so the last match
  # is the newest.
  local b latest=""
  for b in "$f".rcd-bak-*; do
    [ -f "$b" ] || continue
    latest=$b
  done
  if [ -n "$latest" ]; then printf '%s\n' "$latest"; fi
}

cat <<PLAN
remote-claude-desk server uninstall

  user                $DESK_USER (home $DESK_HOME)
  backup set          ${WANT_STAMP:-newest available}

Will restore from backup, if one exists:
  /etc/xrdp/xrdp.ini            $(newest_backup /etc/xrdp/xrdp.ini || true)
  /etc/xrdp/sesman.ini          $(newest_backup /etc/xrdp/sesman.ini || true)
  /etc/pam.d/xrdp-sesman        $(newest_backup /etc/pam.d/xrdp-sesman || true)

Will remove:
  /etc/systemd/system/xrdp-lock-user.service (stopped and disabled first)
  /etc/systemd/system/xrdp-sesman.service.d/reap-orphans.conf
  /usr/local/sbin/xrdp-reap-orphans
  $DESK_HOME/.local/share/applications/claude-desktop-isolated.desktop
  $DESK_HOME/.local/share/applications/claude-desktop.desktop (the NoDisplay shadow)
  $DESK_ISOLATED_ROOT/bin/claude-desktop-isolated
PLAN
if [ "$KEEP_GROUP" = 1 ]; then
  say "  group ssl-cert   left alone (--keep-group)"
else
  say "  group ssl-cert   user 'xrdp' removed from it"
fi
cat <<PLAN

Will NOT touch:
  $DESK_ISOLATED_ROOT itself, so profile, work and logs stay where they are.
  The backup files. Delete them yourself once you are happy.
PLAN

if [ "$ASSUME_YES" != 1 ]; then
  [ -t 0 ] || die "Not a terminal and --yes was not passed. Refusing to guess."
  printf '\nProceed? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) say "Nothing changed."; exit 0 ;; esac
fi

NEEDS_XRDP_RESTART=0
NEEDS_SESMAN_RESTART=0

restore() {  # restore <file> <restart-flag-name>
  local f=$1 flag=$2 b
  b=$(newest_backup "$f" || true)
  if [ -z "$b" ]; then
    skip "no backup found for $f, left as it is"
    return 0
  fi
  if $SUDO cmp -s -- "$b" "$f"; then
    skip "$f already matches $b"
    return 0
  fi
  $SUDO cp --no-preserve=mode,ownership -- "$b" "$f"
  did "restored $f from $b"
  printf -v "$flag" '%s' 1
}

step "1. restore /etc/xrdp/xrdp.ini"
restore /etc/xrdp/xrdp.ini NEEDS_XRDP_RESTART

step "2. restore /etc/xrdp/sesman.ini"
restore /etc/xrdp/sesman.ini NEEDS_SESMAN_RESTART

step "3. remove xrdp-lock-user.service"
LOCK_UNIT=/etc/systemd/system/xrdp-lock-user.service
LOCK_PORT=""
if [ -f "$LOCK_UNIT" ]; then
  LOCK_PORT=$(sed -n 's/.*--dport \([0-9][0-9]*\).*/\1/p' "$LOCK_UNIT" | head -n 1)
fi
if [ -f "$LOCK_UNIT" ]; then
  # Stop before removing, so ExecStop deletes the iptables rules. Delete the
  # unit first and the rules stay in the running firewall with nothing left to
  # remove them, and the port keeps rejecting after a reboot until you notice.
  $SUDO systemctl disable --now xrdp-lock-user.service >/dev/null 2>&1 || true
  $SUDO rm -f "$LOCK_UNIT"
  $SUDO systemctl daemon-reload
  did "stopped, disabled and removed xrdp-lock-user.service"
else
  skip "xrdp-lock-user.service is not installed"
fi
if [ -n "$LOCK_PORT" ] && $SUDO iptables -S OUTPUT 2>/dev/null | grep -q -- "--dport $LOCK_PORT"; then
  warn "iptables OUTPUT still holds a rule for port $LOCK_PORT. Check: sudo iptables -S OUTPUT"
fi

step "4. remove the reaper and its drop-in"
if [ -f /etc/systemd/system/xrdp-sesman.service.d/reap-orphans.conf ]; then
  $SUDO rm -f /etc/systemd/system/xrdp-sesman.service.d/reap-orphans.conf
  $SUDO rmdir /etc/systemd/system/xrdp-sesman.service.d 2>/dev/null || true
  $SUDO systemctl daemon-reload
  did "removed the sesman drop-in"
  NEEDS_SESMAN_RESTART=1
else
  skip "no sesman drop-in installed"
fi
if [ -f /usr/local/sbin/xrdp-reap-orphans ]; then
  $SUDO rm -f /usr/local/sbin/xrdp-reap-orphans
  did "removed /usr/local/sbin/xrdp-reap-orphans"
else
  skip "/usr/local/sbin/xrdp-reap-orphans is not installed"
fi

step "5. restore /etc/pam.d/xrdp-sesman"
if [ -f /etc/pam.d/xrdp-sesman ] && grep -q 'remote-claude-desk' /etc/pam.d/xrdp-sesman; then
  b=$(newest_backup /etc/pam.d/xrdp-sesman || true)
  if [ -n "$b" ]; then
    $SUDO cp --no-preserve=mode,ownership -- "$b" /etc/pam.d/xrdp-sesman
    did "restored /etc/pam.d/xrdp-sesman from $b"
  else
    # No backup, so strip our own block instead of guessing at the original.
    tmp=$(mktemp)
    awk '!/pam_gnome_keyring\.so/ && !/^# Added by remote-claude-desk/' \
      /etc/pam.d/xrdp-sesman >"$tmp"
    $SUDO cp --no-preserve=mode,ownership -- "$tmp" /etc/pam.d/xrdp-sesman
    rm -f "$tmp"
    did "stripped the remote-claude-desk pam block (no backup was found)"
  fi
  NEEDS_SESMAN_RESTART=1
else
  skip "no remote-claude-desk lines in /etc/pam.d/xrdp-sesman"
fi

step "6. remove the isolated Claude Desktop launcher"
for f in \
  "$DESK_ISOLATED_ROOT/bin/claude-desktop-isolated" \
  "$DESK_HOME/.local/share/applications/claude-desktop-isolated.desktop" \
  "$DESK_HOME/.local/share/applications/claude-desktop.desktop"
do
  if [ -f "$f" ]; then
    $SUDO rm -f "$f"
    did "removed $f"
  else
    skip "not present: $f"
  fi
done
if [ -d "$DESK_ISOLATED_ROOT" ]; then
  say "   kept: $DESK_ISOLATED_ROOT (profile, work and logs are still there)"
fi

step "7. group membership"
if [ "$KEEP_GROUP" = 1 ]; then
  skip "left user xrdp in ssl-cert (--keep-group)"
elif id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -qx ssl-cert; then
  $SUDO gpasswd -d xrdp ssl-cert >/dev/null
  did "removed user xrdp from group ssl-cert"
  warn "TLS connections to xrdp will fail again until it is added back."
  NEEDS_XRDP_RESTART=1
else
  skip "user xrdp is not in ssl-cert"
fi

step "restarts"
if [ "$NEEDS_XRDP_RESTART" = 1 ]; then
  if session_live; then
    warn "xrdp needs a restart but a session is live. Skipped. Run later: sudo systemctl restart xrdp"
  else
    if $SUDO systemctl restart xrdp; then did "restarted xrdp"; else warn "could not restart xrdp"; fi
  fi
else
  skip "xrdp needs no restart"
fi

if [ "$NEEDS_SESMAN_RESTART" = 1 ]; then
  if session_live; then
    warn "REFUSING to restart xrdp-sesman: a session for $DESK_USER is live."
    warn "Restarting now would orphan it, and every later connect would open a"
    warn "window that closes at once. Disconnect the session, then re-run this script."
  else
    if $SUDO systemctl restart xrdp-sesman; then did "restarted xrdp-sesman"; else warn "could not restart xrdp-sesman"; fi
  fi
else
  skip "xrdp-sesman needs no restart"
fi

cat <<CHECK

Uninstall finished. Check it with:

  systemctl status xrdp-lock-user            # should say "could not be found"
  systemctl cat xrdp-sesman | grep -c reap   # should print 0
  sudo iptables -S OUTPUT | grep -c uid-owner
  sudo ss -ltnp | grep xrdp                  # back on the packaged address and port

Backups were left in place. Remove them yourself:
  sudo rm /etc/xrdp/*.rcd-bak-* /etc/pam.d/*.rcd-bak-*
CHECK
