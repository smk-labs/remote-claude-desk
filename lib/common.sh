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

  export DESK_HOST DESK_USER DESK_SSH_SOCKET DESK_DISPLAY_MIN DESK_CONFIG_FILE
}

# ─── ssh ─────────────────────────────────────────────────────────────────────

# Every remote call goes through here, so every remote call has a ceiling. An
# ssh with no ConnectTimeout against a box that is up but not answering hangs
# for minutes, which reads on screen as `desk` being broken.
desk_ssh() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes -S "$DESK_SSH_SOCKET" "$DESK_HOST" "$@"
}

desk_master_up() {
  ssh -S "$DESK_SSH_SOCKET" -O check "$DESK_HOST" >/dev/null 2>&1
}

# Bring the multiplexed master up if it is down.
#
# The login dance is the one thing that differs at every site: a plain key here,
# a TOTP prompt there, a hardware key, a jump host. So the default is the boring
# one and DESK_CONNECT_CMD is the seam. Two real adapters, not a hypothetical.
desk_ensure_master() {
  desk_master_up && return 0
  desk_say "SSH master is down, bringing it up..."

  if [ -n "${DESK_CONNECT_CMD:-}" ]; then
    # Deliberately eval'd: the hook is a command line from the user's own
    # config, and it needs $DESK_SSH_SOCKET and $DESK_HOST expanded inside it.
    eval "$DESK_CONNECT_CMD" || desk_die "DESK_CONNECT_CMD failed."
  else
    ssh -fNM -S "$DESK_SSH_SOCKET" "$DESK_HOST" \
      || desk_die "Could not open an SSH master to $DESK_HOST."
  fi

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    desk_master_up && return 0
    sleep 1
  done
  desk_die "SSH master did not come up within 10s."
}

# Forward the RDP port and prove something answers on it. A forward that fails
# is silent by default, and the next thing you see is FreeRDP failing to connect
# for a reason that looks like the server's fault.
desk_forward() {
  ssh -S "$DESK_SSH_SOCKET" -O forward \
      -L "${DESK_LOCAL_PORT}:${DESK_RDP_ADDR}:${DESK_RDP_PORT}" "$DESK_HOST" 2>/dev/null
  nc -z -G 3 127.0.0.1 "$DESK_LOCAL_PORT" 2>/dev/null \
    || desk_die "Tunnel is not answering on 127.0.0.1:${DESK_LOCAL_PORT}."
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

# ─── which display ───────────────────────────────────────────────────────────

# Ask the server which X display this session is actually on.
#
# This used to be the constant :150, and that is wrong often enough to matter:
# when a session fails to start on :150, xrdp hands out :151 next, and every
# assumption downstream then targets a display that is not there. The keyboard
# layout is pushed at nothing and the clipboard bridge owns a selection nobody
# reads. Both fail silently, which is the worst way for them to fail.
#
# Two independent guards, because this box is shared with other tenants who run
# Xvfb with -ac and therefore have access control off: the display number must
# be at or above DESK_DISPLAY_MIN, and its socket must be owned by us. A display
# that fails either test is not ours to touch.
desk_remote_display() {
  if [ -n "${DESK_DISPLAY:-}" ]; then
    printf '%s\n' "$DESK_DISPLAY"
    return 0
  fi

  local found
  found="$(desk_ssh "MIN='$DESK_DISPLAY_MIN' bash -s" 2>/dev/null <<'REMOTE'
me="$(id -un)"

# Candidates: the display number on the command line of every xrdp X server
# this user owns. xrdp's Xorg is told ":N ... -config xrdp/xorg.conf", and the
# other tenants run Xvfb, so that config path is what separates ours from
# theirs.
candidates=""
for p in $(pgrep -u "$me" -x Xorg 2>/dev/null); do
  cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" || continue
  case "$cmd" in *xrdp/xorg.conf*) ;; *) continue ;; esac
  for tok in $cmd; do
    case "$tok" in
      :[0-9]*) candidates="$candidates ${tok#:}"; break ;;
    esac
  done
done

# Fallback: any X socket we own. Covers a session whose Xorg is named
# differently, and costs nothing when the loop above already found it.
if [ -z "$candidates" ]; then
  for s in /tmp/.X11-unix/X*; do
    [ -S "$s" ] || continue
    [ "$(stat -c %U "$s" 2>/dev/null)" = "$me" ] || continue
    candidates="$candidates ${s##*/X}"
  done
fi

for n in $(printf '%s\n' $candidates | sort -n -u); do
  case "$n" in ''|*[!0-9]*) continue ;; esac
  [ "$n" -ge "$MIN" ] || continue
  [ "$(stat -c %U "/tmp/.X11-unix/X$n" 2>/dev/null)" = "$me" ] || continue
  printf ':%s\n' "$n"
  exit 0
done
exit 1
REMOTE
)"

  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
