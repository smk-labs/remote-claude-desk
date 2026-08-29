#!/usr/bin/env bash
# remote-claude-desk, server side. Run this ON the Ubuntu box, not on the Mac.
#
# It makes four changes to xrdp plus two optional ones for Claude Desktop. Every
# step checks first and skips if it is already done, so re-running is safe and
# boring. Nothing is touched before you confirm the plan.
#
# CRITICAL SAFETY RULE: never restart xrdp-sesman while a session is live.
# sesman keeps its session list in memory. A session that survives a restart is
# untracked forever, so every later connect makes a NEW session, which dies at
# once because XFCE cannot start twice for one user, and takes the client with
# it. The user then sees a window that opens and closes and no error anywhere.
# This script detects a live session and refuses to restart sesman. Disconnect
# first, then re-run.

set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
BAK_SUFFIX=".rcd-bak-$STAMP"   # uninstall.sh finds backups by this pattern

# ─── defaults ────────────────────────────────────────────────────────────────
# Under sudo, id -un says root. SUDO_USER is the human who typed the command,
# which is the account that will actually own the desktop session.
DESK_USER="${SUDO_USER:-$(id -un)}"
DESK_RDP_ADDR="127.0.0.77"
DESK_RDP_PORT="33890"
DESK_DISPLAY_MIN="150"
DESK_ISOLATED_ROOT=""          # filled from the target user's home below
DO_KEYRING=0
DO_CLAUDE=0
ASSUME_YES=0

usage() {
  cat <<USAGE
Usage: sudo ./install.sh [options]

  --user NAME            account that owns the desktop session (default: $DESK_USER)
  --rdp-addr ADDR        loopback address xrdp listens on (default: $DESK_RDP_ADDR)
  --rdp-port PORT        port xrdp listens on (default: $DESK_RDP_PORT)
  --display-min N        lowest X display number to hand out (default: $DESK_DISPLAY_MIN)
  --isolated-root DIR    home of the isolated Claude Desktop (default: <user home>/claude-isolated)
  --keyring              add pam_gnome_keyring to xrdp-sesman (needed for Claude Desktop logins)
  --claude               install the isolated Claude Desktop launcher and menu entry
  --yes                  skip the confirmation prompt
  --help                 print this and exit
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user)           DESK_USER="${2:?--user needs a value}"; shift 2 ;;
    --rdp-addr)       DESK_RDP_ADDR="${2:?--rdp-addr needs a value}"; shift 2 ;;
    --rdp-port)       DESK_RDP_PORT="${2:?--rdp-port needs a value}"; shift 2 ;;
    --display-min)    DESK_DISPLAY_MIN="${2:?--display-min needs a value}"; shift 2 ;;
    --isolated-root)  DESK_ISOLATED_ROOT="${2:?--isolated-root needs a value}"; shift 2 ;;
    --keyring)        DO_KEYRING=1; shift ;;
    --claude)         DO_CLAUDE=1; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --help|-h)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ─── small helpers ───────────────────────────────────────────────────────────
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

# Dropping to another account needs a real tool even when we are already root,
# so this cannot reuse $SUDO, which is empty in that case.
if command -v sudo >/dev/null 2>&1; then
  run_as() { local u=$1; shift; sudo -u "$u" -H "$@"; }
elif command -v runuser >/dev/null 2>&1; then
  run_as() { local u=$1; shift; runuser -u "$u" -- "$@"; }
else
  die "Need sudo or runuser to run commands as another account."
fi

# ─── resolve the target user ─────────────────────────────────────────────────
getent passwd "$DESK_USER" >/dev/null || die "No such user: $DESK_USER"
DESK_UID=$(id -u "$DESK_USER")
DESK_HOME=$(getent passwd "$DESK_USER" | cut -d: -f6)
[ -d "$DESK_HOME" ] || die "Home directory of $DESK_USER does not exist: $DESK_HOME"
[ -n "$DESK_ISOLATED_ROOT" ] || DESK_ISOLATED_ROOT="$DESK_HOME/claude-isolated"

case "$DESK_RDP_PORT" in ''|*[!0-9]*) die "--rdp-port must be a number" ;; esac
case "$DESK_DISPLAY_MIN" in ''|*[!0-9]*) die "--display-min must be a number" ;; esac

for f in xrdp-lock-user.service claude-desktop-isolated xrdp-reap-orphans; do
  [ -f "$SELF_DIR/$f" ] || die "Missing $SELF_DIR/$f. Run install.sh from the repo's server/ directory."
done

# ─── a live session blocks anything that needs sesman restarted ──────────────
# Every xrdp X server is started with xrdp/xorg.conf, so this pattern finds a
# real session and nothing else.
session_live() { pgrep -u "$DESK_USER" -f 'xrdp/xorg.conf' >/dev/null 2>&1; }

if session_live; then
  SESSION_NOTE="A session for $DESK_USER is LIVE. Steps that need a restart will be staged, not applied."
else
  SESSION_NOTE="No live session for $DESK_USER. Services can be restarted safely."
fi

# ─── the plan ────────────────────────────────────────────────────────────────
cat <<PLAN
remote-claude-desk server install

  user                $DESK_USER (uid $DESK_UID, home $DESK_HOME)
  xrdp listener       $DESK_RDP_ADDR:$DESK_RDP_PORT
  lowest X display    $DESK_DISPLAY_MIN
  backup suffix       $BAK_SUFFIX

Will change:
  1. group      add user 'xrdp' to group 'ssl-cert' (so it can read /etc/xrdp/key.pem)
  2. config     /etc/xrdp/xrdp.ini      port -> tcp://$DESK_RDP_ADDR:$DESK_RDP_PORT   (backed up)
                /etc/xrdp/sesman.ini    X11DisplayOffset=$DESK_DISPLAY_MIN, Policy=UBI (backed up)
  3. service    /etc/systemd/system/xrdp-lock-user.service, enabled and started
  4. script     /usr/local/sbin/xrdp-reap-orphans (0755)
                /etc/systemd/system/xrdp-sesman.service.d/reap-orphans.conf (drop-in)
PLAN
if [ "$DO_KEYRING" = 1 ]; then
  say "  5. pam        /etc/pam.d/xrdp-sesman gains two pam_gnome_keyring lines (backed up)"
else
  say "  5. pam        SKIPPED (pass --keyring to unlock the login keyring at RDP login)"
fi
if [ "$DO_CLAUDE" = 1 ]; then
  say "  6. claude     $DESK_ISOLATED_ROOT/bin/claude-desktop-isolated (root chmod 700)"
  say "                $DESK_HOME/.local/share/applications/claude-desktop-isolated.desktop"
  say "                a user-level claude-desktop.desktop with NoDisplay=true, to hide the shared one"
else
  say "  6. claude     SKIPPED (pass --claude to install the isolated launcher)"
fi
cat <<PLAN

Will NOT change:
  the packaged xrdp units, sshd, the firewall beyond the one loopback rule,
  any other user's files, and $DESK_HOME/.claude or $DESK_HOME/.claude.json.

$SESSION_NOTE
PLAN

if [ "$ASSUME_YES" != 1 ]; then
  [ -t 0 ] || die "Not a terminal and --yes was not passed. Refusing to guess."
  printf '\nProceed? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) say "Nothing changed."; exit 0 ;; esac
fi

# ─── file helpers ────────────────────────────────────────────────────────────
backup_once() {  # backup_once <file>; one backup per run, never overwritten
  local f=$1
  [ -f "$f" ] || return 0
  if [ -f "$f$BAK_SUFFIX" ]; then return 0; fi
  $SUDO cp -p -- "$f" "$f$BAK_SUFFIX"
  did "backed up $f to $f$BAK_SUFFIX"
}

esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

subst() {  # subst <src> ; writes the filled template to stdout
  sed -e "s|@DESK_USER@|$(esc "$DESK_USER")|g" \
      -e "s|@DESK_HOME@|$(esc "$DESK_HOME")|g" \
      -e "s|@DESK_RDP_ADDR@|$(esc "$DESK_RDP_ADDR")|g" \
      -e "s|@DESK_RDP_PORT@|$(esc "$DESK_RDP_PORT")|g" \
      -e "s|@DESK_DISPLAY_MIN@|$(esc "$DESK_DISPLAY_MIN")|g" \
      -e "s|@DESK_ISOLATED_ROOT@|$(esc "$DESK_ISOLATED_ROOT")|g" \
      -- "$1"
}

install_if_changed() {  # install_if_changed <tmpfile> <dest> <mode> <label>
  local src=$1 dest=$2 mode=$3 label=$4
  if [ -f "$dest" ] && $SUDO cmp -s -- "$src" "$dest"; then
    skip "$label already matches $dest"
    return 1
  fi
  $SUDO install -D -m "$mode" -- "$src" "$dest"
  did "wrote $dest"
  return 0
}

ini_set() {  # ini_set <file> <section> <key> <value>; returns 1 if nothing changed
  local file=$1 section=$2 key=$3 val=$4 tmp
  [ -f "$file" ] || die "Missing $file. Is xrdp installed?"
  tmp=$(mktemp)
  if ! grep -q "^[[:space:]]*\[$section\]" "$file"; then
    { cat "$file"; printf '\n[%s]\n%s=%s\n' "$section" "$key" "$val"; } >"$tmp"
  else
    awk -v sec="$section" -v key="$key" -v val="$val" '
      BEGIN { insec = 0; done = 0 }
      /^[[:space:]]*\[/ {
        if (insec && !done) { print key "=" val; done = 1 }
        insec = ($0 ~ "^[[:space:]]*\\[" sec "\\][[:space:]]*$")
      }
      {
        if (insec && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
          if (!done) { print key "=" val; done = 1 }
          next
        }
        print
      }
      END { if (insec && !done) print key "=" val }
    ' "$file" >"$tmp"
  fi
  if $SUDO cmp -s -- "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  backup_once "$file"
  $SUDO cp --no-preserve=mode,ownership -- "$tmp" "$file"
  rm -f "$tmp"
  return 0
}

# Bounded wait. An unbounded loop here would hang the whole install on a unit
# that is never going to come up.
wait_active() {  # wait_active <unit> ; up to 10 tries, one second apart
  local unit=$1 tries=0
  while [ "$tries" -lt 10 ]; do
    if $SUDO systemctl is-active --quiet "$unit"; then return 0; fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}

NEEDS_XRDP_RESTART=0
NEEDS_SESMAN_RESTART=0

# ─── 1. xrdp reads its own TLS key ───────────────────────────────────────────
# Ubuntu creates the xrdp user outside group ssl-cert, but /etc/xrdp/key.pem is
# ssl-cert 0640. So xrdp cannot read its own key and every TLS connection fails
# with a handshake error that names nothing useful.
step "1. group membership: xrdp in ssl-cert"
if ! getent group ssl-cert >/dev/null; then
  warn "group ssl-cert does not exist. Skipping; xrdp is probably not installed."
elif id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -qx ssl-cert; then
  skip "user xrdp is already in ssl-cert"
else
  $SUDO usermod -aG ssl-cert xrdp
  did "added xrdp to ssl-cert"
  NEEDS_XRDP_RESTART=1
fi
if [ -f /etc/xrdp/key.pem ]; then
  if run_as xrdp test -r /etc/xrdp/key.pem; then
    did "verified: user xrdp can read /etc/xrdp/key.pem"
  else
    warn "user xrdp still cannot read /etc/xrdp/key.pem. Check its mode and group."
  fi
fi

# ─── 2. the listener and the display floor ───────────────────────────────────
# A dedicated loopback address cannot collide with anything else on a shared
# box, and the SSH tunnel is the only way in. X11DisplayOffset keeps sessions
# above the low display numbers other tenants own, several of which run Xvfb
# with -ac, which turns X access control off entirely.
step "2. xrdp.ini listener and sesman.ini display floor"
if ini_set /etc/xrdp/xrdp.ini Globals port "tcp://$DESK_RDP_ADDR:$DESK_RDP_PORT"; then
  did "xrdp.ini port=tcp://$DESK_RDP_ADDR:$DESK_RDP_PORT"
  NEEDS_XRDP_RESTART=1
else
  skip "xrdp.ini already listens on $DESK_RDP_ADDR:$DESK_RDP_PORT"
fi
# Some builds also carry a separate address= key. Left alone it would override
# the address half of port= and put the listener back on every interface.
if grep -q "^[[:space:]]*address[[:space:]]*=" /etc/xrdp/xrdp.ini; then
  if ini_set /etc/xrdp/xrdp.ini Globals address "$DESK_RDP_ADDR"; then
    did "xrdp.ini address=$DESK_RDP_ADDR"
    NEEDS_XRDP_RESTART=1
  else
    skip "xrdp.ini address is already $DESK_RDP_ADDR"
  fi
fi
if ini_set /etc/xrdp/sesman.ini Sessions X11DisplayOffset "$DESK_DISPLAY_MIN"; then
  did "sesman.ini X11DisplayOffset=$DESK_DISPLAY_MIN"
  NEEDS_SESMAN_RESTART=1
else
  skip "sesman.ini X11DisplayOffset is already $DESK_DISPLAY_MIN"
fi
# Policy=UBI gives one session per user, per bit depth, per IP. Without it a
# reconnect from a new source port can start a second session for the same user,
# and the second XFCE dies on the spot.
if ini_set /etc/xrdp/sesman.ini Sessions Policy UBI; then
  did "sesman.ini Policy=UBI"
  NEEDS_SESMAN_RESTART=1
else
  skip "sesman.ini Policy is already UBI"
fi

# ─── 3. lock the listener to one uid ─────────────────────────────────────────
# The loopback address is reachable by every account on a shared box. This rule
# rejects any connection to it that is not owned by the desktop user, so a
# neighbour cannot reach the RDP login prompt at all.
step "3. xrdp-lock-user.service"
TMP_UNIT=$(mktemp)
subst "$SELF_DIR/xrdp-lock-user.service" >"$TMP_UNIT"
if install_if_changed "$TMP_UNIT" /etc/systemd/system/xrdp-lock-user.service 0644 "unit"; then
  $SUDO systemctl daemon-reload
  did "daemon-reload"
  $SUDO systemctl restart xrdp-lock-user.service
else
  $SUDO systemctl start xrdp-lock-user.service 2>/dev/null || true
fi
rm -f "$TMP_UNIT"
if $SUDO systemctl is-enabled --quiet xrdp-lock-user.service 2>/dev/null; then
  skip "xrdp-lock-user.service already enabled"
else
  $SUDO systemctl enable xrdp-lock-user.service >/dev/null
  did "enabled xrdp-lock-user.service"
fi
if wait_active xrdp-lock-user.service; then
  did "xrdp-lock-user.service is active"
else
  warn "xrdp-lock-user.service did not become active within 10 seconds. Check: systemctl status xrdp-lock-user"
fi

# ─── 4. reap orphaned X servers before sesman starts ─────────────────────────
step "4. xrdp-reap-orphans and its sesman drop-in"
install_if_changed "$SELF_DIR/xrdp-reap-orphans" /usr/local/sbin/xrdp-reap-orphans 0755 "reaper" || true
# A drop-in, never an edit of the packaged unit: a package upgrade would
# silently take an edit back out, and this is exactly the line whose absence is
# invisible until a session mysteriously dies.
DROPIN=/etc/systemd/system/xrdp-sesman.service.d/reap-orphans.conf
TMP_DROPIN=$(mktemp)
cat >"$TMP_DROPIN" <<'DROPIN_BODY'
# Added by remote-claude-desk. Kills xrdp X servers that outlived sesman.
[Service]
ExecStartPre=/usr/local/sbin/xrdp-reap-orphans
DROPIN_BODY
if install_if_changed "$TMP_DROPIN" "$DROPIN" 0644 "drop-in"; then
  $SUDO systemctl daemon-reload
  did "daemon-reload"
  NEEDS_SESMAN_RESTART=1
fi
rm -f "$TMP_DROPIN"

# ─── 5. unlock the login keyring at RDP login ────────────────────────────────
step "5. pam_gnome_keyring in xrdp-sesman"
if [ "$DO_KEYRING" != 1 ]; then
  skip "not requested (pass --keyring)"
elif [ ! -f /etc/pam.d/xrdp-sesman ]; then
  warn "/etc/pam.d/xrdp-sesman is missing. Is xrdp installed?"
elif grep -q 'pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman; then
  skip "pam_gnome_keyring is already in /etc/pam.d/xrdp-sesman"
else
  # Without these, the session keyring stays locked. Claude Desktop then cannot
  # write its token to org.freedesktop.secrets, so the login does not persist
  # and every reconnect asks you to sign in again.
  # Appended, not inserted: the file ends with @include lines, so appending puts
  # both lines after the stacks they must follow.
  backup_once /etc/pam.d/xrdp-sesman
  $SUDO tee -a /etc/pam.d/xrdp-sesman >/dev/null <<'PAM_BODY'

# Added by remote-claude-desk: unlock the login keyring with the RDP password.
auth optional pam_gnome_keyring.so
session optional pam_gnome_keyring.so auto_start
PAM_BODY
  did "appended two pam_gnome_keyring lines"
  NEEDS_SESMAN_RESTART=1
fi

# ─── 6. the isolated Claude Desktop ──────────────────────────────────────────
step "6. isolated Claude Desktop"
if [ "$DO_CLAUDE" != 1 ]; then
  skip "not requested (pass --claude)"
else
  run_as_user() { run_as "$DESK_USER" "$@"; }
  run_as_user mkdir -p "$DESK_ISOLATED_ROOT/bin" "$DESK_HOME/.local/share/applications"
  run_as_user chmod 700 "$DESK_ISOLATED_ROOT"
  did "created $DESK_ISOLATED_ROOT (mode 700)"

  TMP_LAUNCHER=$(mktemp)
  subst "$SELF_DIR/claude-desktop-isolated" >"$TMP_LAUNCHER"
  LAUNCHER="$DESK_ISOLATED_ROOT/bin/claude-desktop-isolated"
  if cmp -s "$TMP_LAUNCHER" "$LAUNCHER" 2>/dev/null; then
    skip "launcher already matches $LAUNCHER"
  else
    $SUDO install -o "$DESK_USER" -g "$DESK_USER" -m 0700 -- "$TMP_LAUNCHER" "$LAUNCHER"
    did "wrote $LAUNCHER"
  fi
  rm -f "$TMP_LAUNCHER"

  DESKTOP_DIR="$DESK_HOME/.local/share/applications"
  TMP_ENTRY=$(mktemp)
  cat >"$TMP_ENTRY" <<ENTRY_BODY
[Desktop Entry]
Type=Application
Name=Claude (isolated)
Comment=Claude Desktop with its own config, cache and profile
Exec=$LAUNCHER %U
Icon=claude-desktop
Terminal=false
Categories=Development;Utility;
StartupWMClass=Claude
ENTRY_BODY
  ENTRY="$DESKTOP_DIR/claude-desktop-isolated.desktop"
  if cmp -s "$TMP_ENTRY" "$ENTRY" 2>/dev/null; then
    skip "menu entry already matches $ENTRY"
  else
    $SUDO install -o "$DESK_USER" -g "$DESK_USER" -m 0644 -- "$TMP_ENTRY" "$ENTRY"
    did "wrote $ENTRY"
  fi
  rm -f "$TMP_ENTRY"

  # Hide the packaged launcher. Clicking it starts Claude Desktop against the
  # central ~/.claude, which is the whole thing this setup exists to avoid.
  # A user-level copy with NoDisplay=true shadows the system entry by desktop
  # file id, so the packaged file itself stays untouched and survives upgrades.
  if [ -f /usr/share/applications/claude-desktop.desktop ]; then
    HIDDEN="$DESKTOP_DIR/claude-desktop.desktop"
    TMP_HIDDEN=$(mktemp)
    grep -v '^NoDisplay=' /usr/share/applications/claude-desktop.desktop >"$TMP_HIDDEN" || true
    printf 'NoDisplay=true\n' >>"$TMP_HIDDEN"
    if cmp -s "$TMP_HIDDEN" "$HIDDEN" 2>/dev/null; then
      skip "packaged entry is already hidden"
    else
      $SUDO install -o "$DESK_USER" -g "$DESK_USER" -m 0644 -- "$TMP_HIDDEN" "$HIDDEN"
      did "hid the packaged launcher with $HIDDEN"
    fi
    rm -f "$TMP_HIDDEN"
  else
    skip "no packaged claude-desktop.desktop found, nothing to hide"
  fi
fi

# ─── restarts, or a refusal ──────────────────────────────────────────────────
step "restarts"
if [ "$NEEDS_XRDP_RESTART" = 1 ]; then
  if session_live; then
    warn "xrdp needs a restart but a session is live. It would disconnect you. Skipped."
    warn "Run later: sudo systemctl restart xrdp"
  else
    $SUDO systemctl restart xrdp
    if wait_active xrdp; then did "restarted xrdp"; else warn "xrdp did not come up within 10 seconds"; fi
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
    $SUDO systemctl restart xrdp-sesman
    if wait_active xrdp-sesman; then did "restarted xrdp-sesman"; else warn "xrdp-sesman did not come up within 10 seconds"; fi
  fi
else
  skip "xrdp-sesman needs no restart"
fi

# ─── verify ──────────────────────────────────────────────────────────────────
cat <<CHECK

Install finished. Check it with these, in order:

  sudo -u xrdp test -r /etc/xrdp/key.pem && echo "key readable"
  sudo ss -ltnp | grep '$DESK_RDP_PORT'                 # xrdp on $DESK_RDP_ADDR only
  systemctl is-active xrdp xrdp-sesman xrdp-lock-user
  sudo iptables -S OUTPUT | grep '$DESK_RDP_PORT'       # two rules, reject then accept
  systemctl cat xrdp-sesman | grep reap-orphans         # the drop-in is in the unit
  grep -E 'X11DisplayOffset|Policy' /etc/xrdp/sesman.ini

Then connect from the Mac. After the first login, confirm your display number
is $DESK_DISPLAY_MIN or higher:

  echo \$DISPLAY

Backups from this run carry the suffix $BAK_SUFFIX.
Undo everything with: sudo ./uninstall.sh --user $DESK_USER
CHECK
