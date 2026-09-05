# The shared library: the retry ceiling, the safe remote kill, and the config
# guard. Each one is a bug that actually happened, so each one gets a test.
# shellcheck shell=bash

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

# --- desk_retry: every wait has a ceiling ------------------------------------
_never() { return 1; }
_always() { return 0; }

start=$SECONDS
desk_retry 3 0 1 -- _never && bad "desk_retry returned success for a failing command" \
                           || ok "desk_retry gives up rather than waiting forever"
is "$((SECONDS - start < 3))" "1" "desk_retry with delay 0 does not sleep"

desk_retry 3 0 1 -- _always && ok "desk_retry returns success when the command passes" \
                            || bad "desk_retry failed a passing command"

# The consecutive count is the part that matters for the keyboard layout: xrdp
# can overwrite the keymap after the first success, so one pass is not proof.
_count=0
_flaky() { _count=$((_count + 1)); [ $((_count % 2)) -eq 0 ]; }
_count=0
desk_retry 8 0 2 -- _flaky && bad "a command that never passes twice in a row was accepted" \
                           || ok "desk_retry needs its passes CONSECUTIVE, not merely frequent"

_count=0
_after_two() { _count=$((_count + 1)); [ "$_count" -ge 2 ]; }
desk_retry 8 0 3 -- _after_two && ok "three consecutive passes are accepted" \
                               || bad "three consecutive passes were rejected"

# --- desk_remote_pkill: the pattern cannot match its own shell ---------------
# `pkill -f` matches the whole command line, so a bare pattern also matches the
# ssh shell running the pkill and kills the cleanup halfway through.
_pattern_for() { local p="$1"; printf '[%s]%s' "${p:0:1}" "${p:1}"; }
is "$(_pattern_for deskclip-agent)" "[d]eskclip-agent" "the kill pattern is bracketed"
lacks "pkill -f '$(_pattern_for deskclip-agent)'" "deskclip-agent" \
      "the literal never appears on the command line that kills it"

# --- every command in bin/ is on the list that puts commands on PATH ---------
# The bug this replaces: `desk-setup` shipped, was executable, was the first word
# of the README's own quick start, and was in none of the three copies of the
# list, so nothing ever linked it. Comparing the list against the directory is
# the only check that catches the next one, because a list that is merely
# self-consistent is still wrong when a file is added beside it.
#
# Nothing is excluded any more. The two helpers that used to be, desk-clip and
# desk-pbio, were found next to `desk` rather than typed, and both went with it.
# desk-clip and desk-pbio are found next to desk-tunnel rather than typed, so
# neither belongs on PATH, and desk-pbio is built rather than committed so a
# clean checkout does not have it.
expected="$(cd "$ROOT/bin" && ls | grep -vE '^(desk-clip|desk-pbio)$' | sort | tr '\n' ' ')"
actual="$(printf '%s ' $(printf '%s\n' $DESK_COMMANDS | sort))"
is "$actual" "$expected" "DESK_COMMANDS lists every command in bin/"

# --- desk_load_config refuses a config anyone else can write -----------------
# It is SOURCED, so everything in it runs.
tmp="$(mktemp -d)"
printf 'DESK_HOST=h\nDESK_USER=u\n' > "$tmp/config.sh"

# HOME is moved somewhere empty for these four, and that is the whole reason they
# mean anything. `desk_load_config` prefers ~/.config/remote-claude-desk/config.sh
# over the one in the repo, so on a machine where the developer actually uses this
# tool every check below was reading their real config instead of the fixture: the
# three refusals "passed" because a 600 file with real values loads, and the
# permission the test had just set was never looked at. Found on 2026-09-01, on
# the first machine that had both a user config and a reason to run the suite.
HOME_BEFORE="$HOME"
mkdir -p "$tmp/home"
HOME="$tmp/home"

chmod 600 "$tmp/config.sh"
( desk_load_config "$tmp" >/dev/null 2>&1 ) && ok "a 600 config loads" \
                                            || bad "a 600 config was refused"

chmod 664 "$tmp/config.sh"
( desk_load_config "$tmp" >/dev/null 2>&1 ) && bad "a group-writable config was accepted" \
                                            || ok "a group-writable config is refused"

chmod 666 "$tmp/config.sh"
( desk_load_config "$tmp" >/dev/null 2>&1 ) && bad "a world-writable config was accepted" \
                                            || ok "a world-writable config is refused"

# The example values must never be run against as if they were real.
chmod 600 "$tmp/config.sh"
printf 'DESK_HOST=mybox\nDESK_USER=me\n' > "$tmp/config.sh"
( desk_load_config "$tmp" >/dev/null 2>&1 ) && bad "the unedited example config was accepted" \
                                            || ok "an unedited example config is refused"

# --- DESK_CONFIG names one file and skips the search -------------------------
# What a second machine needs: the menu bar app runs the same `desk` for every
# row it draws, so the only thing that can differ between rows is the environment.
mkdir -p "$HOME/.config/remote-claude-desk"
printf 'DESK_HOST=fromhome\nDESK_USER=u\n' > "$HOME/.config/remote-claude-desk/config.sh"
chmod 600 "$HOME/.config/remote-claude-desk/config.sh"
printf 'DESK_HOST=named\nDESK_USER=u\n' > "$tmp/other.sh"
chmod 600 "$tmp/other.sh"

got="$( DESK_CONFIG="$tmp/other.sh" bash -c '. "'"$ROOT"'/lib/common.sh"; desk_load_config "'"$tmp"'" >/dev/null 2>&1; printf %s "$DESK_HOST"' )"
is "$got" "named" "DESK_CONFIG wins over the config in the home directory"

got="$( bash -c '. "'"$ROOT"'/lib/common.sh"; desk_load_config "'"$tmp"'" >/dev/null 2>&1; printf %s "$DESK_HOST"' )"
is "$got" "fromhome" "without it, the home directory config still wins"

got="$( DESK_CONFIG="$tmp/other.sh" bash -c '. "'"$ROOT"'/lib/common.sh"; desk_load_config "'"$tmp"'" >/dev/null 2>&1; printf %s "$DESK_CONFIG_FILE"' )"
is "$got" "$tmp/other.sh" "the file it reports is the file it loaded"

# A name that is not there is an error, never a quiet fall back to the config
# that happened to be lying around: that would connect you to the other machine
# and look like it had worked.
( DESK_CONFIG="$tmp/nope.sh" desk_load_config "$tmp" >/dev/null 2>&1 ) \
  && bad "a DESK_CONFIG naming nothing was accepted" \
  || ok "a DESK_CONFIG naming nothing is refused"

HOME="$HOME_BEFORE"
rm -rf "$tmp"

# --- macOS already knows why the client froze --------------------------------
doctor_src="$(cat "$ROOT/bin/desk-doctor")"
contains "$doctor_src" 'DiagnosticReports/sdl-freerdp*.hang' \
         "desk-doctor reads the hang reports macOS files about the client"

# The lock is released on the way out, never by cleanup.
#
# cleanup runs after every client, because that is what the reconnect loop is
# for. A release in there hands the lock back on the first network blip, while
# the desk holding it is still alive and about to open another client, and the
# next desk then walks straight in. Caught live: one desk, one reconnect, no pid
# file left.

# --- a native client still needs the keyboard pushed ------------------------
#
# xrdp sets the session keymap from what the client announces, after
# xfce4-settings has had its say, so every session comes up as plain "us" no
# matter what the server is configured with. `desk` pushes the real layout on
# every connect. desk-tunnel used to say a native client was "on its own" and
# leave it, and what that meant in practice was measured on a live session:
# setxkbmap said layout: us, keycodes 191 to 202 were empty, Persian did not
# exist and the Fn key did nothing.
tunnel_src="$(cat "$ROOT/bin/desk-tunnel")"
contains "$tunnel_src" 'desk_remote_run apply-layout.sh' "desk-tunnel pushes the keyboard layout too"
contains "$tunnel_src" 'Keyboard: ${layout_note}' "desk-tunnel says whether the layout landed"

# --- desk-tunnel keeps itself up and carries the clipboard ------------------
#
# The bridge was never FreeRDP-specific: it is a pair of processes over the SSH
# master and does not know what draws the screen. It is also the only path that
# carries an image, because xrdp 0.9.24's clipboard channel delivers a BMP whose
# header declares more bytes than arrive. ImageMagick refuses it outright with
# "length and filesize do not match", so text crosses on that channel and
# pictures only look like they do.
contains "$tunnel_src" 'com.smk-labs.desk-tunnel.$DESK_HOST' "the LaunchAgent is named per machine"
# macOS ships no setsid. The first version used it and failed with "command not
# found" into a log nobody was watching, which is this repo's whole bad habit in
# one line. Comments are stripped first, because the comment explaining this is
# allowed to name the thing it is warning about.
tunnel_code="$(grep -v '^[[:space:]]*#' "$ROOT/bin/desk-tunnel")"
lacks "$tunnel_code" 'setsid' "desk-tunnel does not reach for setsid on macOS"

# --- every command still loads the library it depends on ---------------------
#
# The bug this replaces, and it was self-inflicted an hour before this test was
# written: a regex meant to delete one stale paragraph from bin/desk-tunnel used
# a non-greedy match across newlines, and it ran past the end of the comment and
# swallowed `set -uo pipefail`, the ROOT assignment, the `. lib/common.sh` line
# and the `desk_load_config` call with it. The file still parsed. shellcheck was
# still clean. All 45 checks still passed, because every one of them greps the
# file rather than running it. What it did at runtime was announce
# "Tunnel up on 127.0.0.1:" with no port and forward nothing.
#
# So: assert the four lines that make a command a command. Any one of them
# missing is a script that starts, prints something reassuring, and does nothing.
# $DESK_COMMANDS, not bin/*: desk-clip is Python and desk-pbio is a compiled
# binary, so neither sources a shell library and neither is on PATH.
for name in $DESK_COMMANDS; do
  cmd="$ROOT/bin/$name"
  src="$(cat "$cmd")"
  contains "$src" 'set -uo pipefail'        "$name sets the shell options"
  contains "$src" '. "$ROOT/lib/common.sh"' "$name sources the library"
  contains "$src" 'desk_load_config "$ROOT"' "$name loads the config"
done

# --- nothing user-facing may name a command that was deleted ------------------
#
# Found by running `desk-tunnel --help`, not by reading it: the last line still
# said "exactly as it is for desk". Every grep in this suite had passed, because
# they all look for what should be present and none looked for what should not.
# bin/ AND mac/, because the guard missed the installers the first time and the
# installers were exactly where the next two lies were: usage() offering to link
# a command that does not exist, and a closing hint telling you to run it.
for cmd in $(for n in $DESK_COMMANDS; do echo "$ROOT/bin/$n"; done; ls "$ROOT"/mac/*.sh); do
  name="$(basename "$cmd")"
  # Comments are stripped first. A comment saying what `desk` used to do is the
  # house style and the reason half this repo is readable; a STRING that tells
  # someone to run it is a lie. Only the second kind is a bug.
  #
  # A bare "desk" with no hyphen after it, so desk-doctor and desk-tunnel pass,
  # and so do DESK_ variables and the repo's own name.
  #
  # No `|| echo 0` either: grep -c always prints a count and exits 1 when that
  # count is zero, so a fallback would fire on success and make the value "0\n0".
  hits="$(grep -v '^[[:space:]]*#' "$cmd" \
          | grep -cE '(^|[^-a-zA-Z_/])desk([^-a-zA-Z_]|$)')"
  is "$hits" "0" "$name names no deleted command"
done

# --- the clipboard bridge carries the direction RDP must not -----------------
#
# Windows App deadlocks when an image reaches the Mac pasteboard while it is
# redirecting the clipboard towards the remote side: a screenshot is enough, and
# it then refuses to reopen the session until the whole app is quit. Known bug,
# unfixed as of 11.4.0. The client redirects no clipboard at all now, so RDP
# carries neither direction and desk-clip carries both.
tunnel_src="$(cat "$ROOT/bin/desk-tunnel")"
contains "$tunnel_src" '"$ROOT/bin/desk-clip"' "desk-tunnel starts the clipboard bridge"
contains "$tunnel_src" 'Clipboard: ${bridge_note}' "desk-tunnel says what the bridge did"
lacks "$tunnel_src" 'DESK_CLIP' "the bridge is not optional any more, so no knob gates it"
[ -x "$ROOT/bin/desk-clip" ] \
  && ok "desk-clip is present" \
  || bad "desk-clip is missing, so nothing carries the Mac to remote clipboard"
[ -f "$ROOT/mac/pbio.swift" ] \
  && ok "the pasteboard reader source is present" \
  || bad "mac/pbio.swift is missing, so images cannot cross"

# --- the clipboard fix must not be able to regress quietly ------------------
#
# Windows App deadlocks when an image reaches the Mac pasteboard while it is
# redirecting the clipboard, so a screenshot over a full-screen session wedges
# everything until the app is quit entirely. The bug is in a closed client. The
# fix is to stop using that path and carry the clipboard over SSH, which costs
# nothing: text and images both cross both ways, verified byte for byte.
#
# It leaves three conditions, all of which fail silently, and one of them did:
# on 2026-09-05 the bridge died during an unrelated outage and the only symptom
# was copy and paste not working. So the doctor asserts all three.
contains "$doctor_src" 'DisableClipboardRedirection' \
         "desk-doctor checks the Mac is not redirecting the clipboard"
contains "$doctor_src" '[d]esk-clip --for' \
         "desk-doctor checks the clipboard bridge is running"
contains "$(cat "$ROOT/remote/check.sh")" 'cliprdr=false' \
         "check.sh checks the RDP clipboard channel is off on the server"
