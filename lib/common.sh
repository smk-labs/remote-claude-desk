# shellcheck shell=bash
# Shared by every desk command. Source it, never run it.
#
# What lives here is the handful of things that were copied into four scripts
# before, and were wrong in a different way in each copy: where the config is,
# how the SSH master comes up, which X display the session is really on, and how
# to kill something on the far side without killing the shell doing the killing.
#
# Each of those is a lesson that cost hours. Putting them behind one function
# each is what stops the next script from learning them again.

# ─── output ──────────────────────────────────────────────────────────────────

desk_say()  { printf '%s\n' "$*"; }
desk_warn() { printf '%s\n' "$*" >&2; }
desk_die()  { printf '%s\n' "$*" >&2; exit 1; }

# ─── where am I ──────────────────────────────────────────────────────────────

# Follow a symlink chain to the real file.
#
# Note that a script locating ITSELF cannot call this, because common.sh is not
# sourced yet at that moment. Those use `/bin/realpath` inline instead, with the
# same reasoning in a comment. This is for resolving OTHER paths, such as
# checking where the symlinks in ~/bin actually point.
#
# Worth having at all because of a bug that shipped: `desk` is meant to be run
# as ~/bin/desk, a symlink into the repo, and BASH_SOURCE holds the path it was
# INVOKED by, not the target. A plain `dirname` gave ~/bin, the helper next to
# it was not found there, and the clipboard bridge silently never started. No
# error, no log line, a desktop that simply never pasted.
desk_resolve() {
  /bin/realpath "$1" 2>/dev/null && return 0
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  printf '%s\n' "$src"
}

# ─── config ──────────────────────────────────────────────────────────────────

# Load config.sh, from the user's config dir first so a clone can stay pristine.
# Exits with instructions rather than running against the example values, which
# would otherwise fail later with a confusing SSH error.
desk_load_config() {
  local root="$1" found=""
  # Where the repo lives, so desk_remote_run can find remote/ no matter which
  # directory the caller was invoked from or symlinked into.
  DESK_ROOT="$root"
  for candidate in \
      "$HOME/.config/remote-claude-desk/config.sh" \
      "$root/config.sh"; do
    [ -f "$candidate" ] && { found="$candidate"; break; }
  done

  if [ -z "$found" ]; then
    desk_warn "No config found. Create one:"
    desk_warn "    cp $root/config.example.sh $root/config.sh"
    desk_warn "    \$EDITOR $root/config.sh     # set DESK_HOST and DESK_USER"
    exit 1
  fi

  # This file is SOURCED, so everything in it runs. That is what makes a
  # per-run override like `DESK_SIZE=... desk` free, and it is also why a
  # config pasted from an issue thread executes on sight. Refuse one that
  # anyone else can write to, which is the case that turns a shared machine
  # into someone else's shell.
  local perms
  perms="$(stat -f '%Lp' "$found" 2>/dev/null || stat -c '%a' "$found" 2>/dev/null || echo "")"
  if [ -n "$perms" ] && [ $(( 8#$perms & 0022 )) -ne 0 ]; then
    desk_die "$found is writable by group or others (mode $perms). Run: chmod 600 $found"
  fi

  # shellcheck disable=SC1090
  . "$found"
  DESK_CONFIG_FILE="$found"

  # Defaults for anything an older config predates, so an upgrade never breaks.
  : "${DESK_RDP_ADDR:=127.0.0.77}"
  : "${DESK_RDP_PORT:=33890}"
  : "${DESK_LOCAL_PORT:=33890}"
  : "${DESK_DISPLAY_MIN:=150}"
  : "${DESK_DISPLAY:=}"
  : "${DESK_LAYOUTS:=us}"
  : "${DESK_LAYOUT_TOGGLE:=grp:alt_shift_toggle}"
  : "${DESK_SHARE:=$HOME/RemoteShare}"
  : "${DESK_KEYCHAIN_SERVICE:=remote-claude-desk}"
  : "${DESK_CONNECT_CMD:=}"
  : "${DESK_SSH_SOCKET:=$HOME/.ssh/ctrl-$DESK_HOST}"

  [ -n "${DESK_HOST:-}" ] || desk_die "DESK_HOST is not set in $found"
  [ -n "${DESK_USER:-}" ] || desk_die "DESK_USER is not set in $found"
  if [ "$DESK_HOST" = "mybox" ]; then
    desk_die "$found still has the example values. Set DESK_HOST and DESK_USER."
  fi

  export DESK_HOST DESK_USER DESK_SSH_SOCKET DESK_DISPLAY_MIN DESK_CONFIG_FILE DESK_ROOT
}

# ─── ssh ─────────────────────────────────────────────────────────────────────

# Every remote call goes through here, so every remote call has a ceiling. An
# ssh with no ConnectTimeout against a box that is up but not answering hangs
# for minutes, which reads on screen as `desk` being broken.
desk_ssh() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes -S "$DESK_SSH_SOCKET" "$DESK_HOST" "$@"
}

# Say WHY the box cannot be reached, instead of "could not open an SSH master".
#
# The three failures below look identical from the outside and have nothing in
# common as fixes, which is the whole reason this exists. The one that cost a
# morning twice is the middle one: a VPN or proxy client installs a route for
# the server's address, TCP still connects because the tunnel accepts it
# locally, and sshd never gets the packet. Ping is fast, the port is "open",
# and every reconnect dies at the banner with no explanation. Naming the
# interface that owns the route is what turns that into a one-line answer.
#
# Bounded on purpose: 5s for the TCP probe, 8s for the banner. A diagnosis that
# hangs is worse than no diagnosis.
desk_reach_report() {
  local addr port iface gw
  addr="$(ssh -G "$DESK_HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  port="$(ssh -G "$DESK_HOST" 2>/dev/null | awk '/^port /{print $2; exit}')"
  [ -n "$addr" ] || { desk_warn "  '$DESK_HOST' is not a host in your ssh config."; return; }
  [ -n "$port" ] || port=22

  if ! nc -z -G 5 "$addr" "$port" 2>/dev/null; then
    desk_warn "  Nothing is accepting TCP on $addr:$port."
    desk_warn "  The box is off, or the network between here and it is down."
    return
  fi

  # TCP is up. Does sshd actually answer? A real sshd sends "SSH-2.0-..." at once.
  if printf '' | nc -G 8 -w 8 "$addr" "$port" 2>/dev/null | head -c 4 | grep -q '^SSH-'; then
    desk_warn "  sshd on $addr:$port answers, so this is a login failure, not the network."
    desk_warn "  Check your key, your 2FA helper, or DESK_CONNECT_CMD in $DESK_CONFIG_FILE."
    return
  fi

  iface="$(route -n get "$addr" 2>/dev/null | awk '/interface:/{print $2; exit}')"
  gw="$(route -n get "$addr" 2>/dev/null | awk '/gateway:/{print $2; exit}')"
  desk_warn "  TCP to $addr:$port connects, but sshd never sends its banner."
  desk_warn "  That means the packets are being swallowed on the way, not refused."
  case "$iface" in
    utun*|ipsec*|tun*|tap*|ppp*)
      desk_warn "  Traffic to $addr is routed over $iface (gateway $gw), which is a VPN"
      desk_warn "  or proxy tunnel, not your normal connection. That tunnel is the cause."
      desk_warn "  Fix: turn the VPN or proxy client off, or add $addr to its direct/bypass"
      desk_warn "  list so the server is reached over the ordinary route."
      ;;
    *)
      desk_warn "  Route to $addr goes over ${iface:-an unknown interface} (gateway ${gw:-unknown})."
      desk_warn "  Suspect a firewall, or sshd being at MaxStartups and dropping new logins."
      ;;
  esac
}

desk_master_up() {
  ssh -S "$DESK_SSH_SOCKET" -O check "$DESK_HOST" >/dev/null 2>&1
}

# Bring the multiplexed master up if it is down.
#
# The login dance is the one thing that differs at every site: a plain key here,
# a TOTP prompt there, a hardware key, a jump host. So the default is the boring
# one and DESK_CONNECT_CMD is the seam. Two real adapters, not a hypothetical.
# One exit point for "the master would not come up", so the diagnosis above is
# printed no matter which of the three ways it failed.
desk_master_failed() {
  desk_warn "$*"
  desk_reach_report
  exit 1
}

desk_ensure_master() {
  desk_master_up && return 0
  desk_say "SSH master is down, bringing it up..."

  if [ -n "${DESK_CONNECT_CMD:-}" ]; then
    # Deliberately eval'd: the hook is a command line from the user's own
    # config, and it needs $DESK_SSH_SOCKET and $DESK_HOST expanded inside it.
    eval "$DESK_CONNECT_CMD" || desk_master_failed "DESK_CONNECT_CMD failed."
  else
    ssh -fNM -S "$DESK_SSH_SOCKET" "$DESK_HOST" \
      || desk_master_failed "Could not open an SSH master to $DESK_HOST."
  fi

  desk_retry 10 1 1 -- desk_master_up \
    || desk_master_failed "SSH master did not come up within 10s."
}

# Forward the RDP port and prove something answers on it. A forward that fails
# is silent by default, and the next thing you see is FreeRDP failing to connect
# for a reason that looks like the server's fault.
desk_forward() {
  _try_forward() {
    ssh -S "$DESK_SSH_SOCKET" -O forward \
        -L "${DESK_LOCAL_PORT}:${DESK_RDP_ADDR}:${DESK_RDP_PORT}" "$DESK_HOST" 2>/dev/null
    nc -z -G 3 127.0.0.1 "$DESK_LOCAL_PORT" 2>/dev/null
  }

  _try_forward && return 0

  # A master that survives a network drop keeps answering `-O check` while every
  # channel through it is already dead, so the forward is accepted and then goes
  # nowhere. That looked like "desk is broken" for two mornings. Tear the master
  # down and build a fresh one, once, rather than reporting a failure the user
  # can only fix by doing exactly this by hand.
  desk_say "tunnel did not answer, rebuilding the SSH connection..."
  ssh -S "$DESK_SSH_SOCKET" -O exit "$DESK_HOST" >/dev/null 2>&1 || true
  desk_ensure_master
  _try_forward && return 0

  desk_warn "Tunnel is not answering on 127.0.0.1:${DESK_LOCAL_PORT}, even after a rebuild."
  desk_reach_report
  exit 1
}

# Kill a process on the far side by pattern, safely.
#
# The bracket is not decoration. `pkill -f` matches the whole command line, so a
# plain pattern also matches the ssh shell that is running the pkill: it kills
# the cleanup halfway through and leaves the rest of the processes alive, with
# exit status 255 and nothing said. Wrapping the first character in a character
# class makes the pattern unable to match itself. Every caller gets this for
# free rather than remembering it.
desk_remote_pkill() {
  local pattern="$1" bracketed
  bracketed="[${pattern:0:1}]${pattern:1}"
  desk_ssh "pkill -f '$bracketed'" >/dev/null 2>&1 || true
}

# ─── running code on the server ──────────────────────────────────────────────

# Run one of the scripts in remote/ on the server.
#
#   desk_remote_run find-display.sh MIN=150
#
# Everything after the script name is a NAME=VALUE pair placed in the remote
# environment. Stdout and the exit status are the script's own.
#
# This function exists because the remote payloads used to be string literals:
# heredocs in three files and a Python r-string in a fourth, five call sites
# with five different shapes. 227 lines, 18% of the code, that `bash -n` and
# `shellcheck` both skip entirely, because a heredoc is data and no parser
# looks inside it. A deliberate syntax error in one of them passed both checks.
#
# As files they are ordinary code: parsed, linted, highlighted and diffable.
# The transport, the quoting and the timeout live here instead of being
# re-derived at every call site.
desk_remote_run() {
  local script="$1"; shift
  local path="$DESK_ROOT/remote/$script"
  [ -f "$path" ] || { desk_warn "missing remote script: $path"; return 1; }

  # The environment is passed as assignments in front of the interpreter rather
  # than interpolated into the script, so a value containing a space, a quote or
  # a dollar sign cannot change what runs.
  local env_prefix="" pair
  for pair in "$@"; do
    env_prefix+="$(printf '%q' "${pair%%=*}")=$(printf '%q' "${pair#*=}") "
  done

  local interp="bash -s"
  case "$script" in *.py) interp="python3 -" ;; esac

  desk_ssh "${env_prefix}${interp}" < "$path"
}

# ─── bounded waiting ─────────────────────────────────────────────────────────

# Retry a command until it passes, with a ceiling. Never waits forever.
#
#   desk_retry 12 2 3 -- some_command args
#            tries ^  ^ delay
#                     ^ how many CONSECUTIVE passes count as success
#
# "Every wait gets a ceiling" was previously obeyed six different ways, each one
# correct and none of them enforced. The seventh loop someone writes is correct
# only if they remember, and the failure mode of forgetting is the worst one
# here: waiting forever with nothing on screen.
#
# The consecutive count is not padding. The keyboard layout genuinely needs
# three passes in a row, because xrdp overwrites the keymap after the first one
# lands, so a single success is not proof.
desk_retry() {
  local tries="$1" delay="$2" need="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local i ok=0
  for ((i = 0; i < tries; i++)); do
    sleep "$delay"
    if "$@"; then
      ok=$((ok + 1))
      [ "$ok" -ge "$need" ] && return 0
    else
      ok=0
    fi
  done
  return 1
}

# ─── which display ───────────────────────────────────────────────────────────

# Ask the server which X display this session is actually on.
#
# This used to be the constant :150, and that is wrong often enough to matter:
# when a session fails to start on :150, xrdp hands out :151 next, and every
# assumption downstream then targets a display that is not there. The keyboard
# layout is pushed at nothing and the clipboard bridge owns a selection nobody
# reads. Both fail silently, which is the worst way for them to fail.
#
# The guards live in remote/find-display.sh, next to the code they guard.
desk_remote_display() {
  if [ -n "${DESK_DISPLAY:-}" ]; then
    printf '%s\n' "$DESK_DISPLAY"
    return 0
  fi
  local found
  found="$(desk_remote_run find-display.sh "MIN=$DESK_DISPLAY_MIN" 2>/dev/null)" || return 1
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
