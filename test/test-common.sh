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
# What a second machine needs. Both LaunchAgents run the same desk-tunnel, so the
# only thing that can differ between them is the environment they carry.
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
#
# The path is Windows App's, and ONLY Windows App's. This read both clients
# while both existed. The day FreeRDP was deleted that turned into a bug: the
# newest .hang on the disk was a FreeRDP one from the day before, so every run
# warned about a freeze in a client that is not installed, and a real Windows
# App hang filed later would have sorted below it and never been seen.
doctor_src="$(cat "$ROOT/bin/desk-doctor")"
contains "$doctor_src" 'DiagnosticReports/Windows App' \
         "desk-doctor reads the hang reports macOS files about the client"
doctor_code="$(grep -v '^[[:space:]]*#' "$ROOT/bin/desk-doctor")"
lacks "$doctor_code" 'sdl-freerdp' "desk-doctor does not report hangs of a client that is gone"

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

# --- the tunnel is proven, not assumed ---------------------------------------
#
# `nc -z` on the local port was the old proof of a working forward, and it is
# not one. Two real failures pass it. A forward request that fails is silent, so
# the port can be answering from something else entirely: on this Mac that means
# the OTHER machine's master, holding the same number, and the client then logs
# into the wrong box with every check green. And a master that survived a
# network drop keeps its listener while every channel through it is dead, so the
# port accepts a connection and carries nothing. That one cost two mornings.
common_code="$(grep -v '^[[:space:]]*#' "$ROOT/lib/common.sh")"
# Scoped to the two functions that decide it. `nc -z` is still right elsewhere:
# desk_reach_report uses it to ask whether the far host answers at all, which is
# a question about reachability and not a claim about the forward.
forward_code="$(awk '/^desk_forward_healthy\(\)/,/^}/' "$ROOT/lib/common.sh"
                awk '/^desk_forward\(\)/,/^}/' "$ROOT/lib/common.sh")"
lacks "$forward_code" 'nc -z' "desk_forward does not treat an open port as proof"
contains "$common_code" 'desk_forward_healthy' "desk_forward asks a question it can be wrong about"
contains "$common_code" '"$opid" = "$mpid"' "the listener must belong to THIS machine's master"
contains "$common_code" 'x03\x00\x00\x13' "the check is a real X.224 handshake, not a connect"

# The probe has to end by itself. A check that can hang is worse than no check:
# the watcher blocks on it and stops watching, which is the failure it exists to
# catch, arriving through the door marked prevention.
contains "$common_code" 'nc -w "${DESK_PROBE_TIMEOUT:-8}"' "the handshake probe has its own ceiling"

# Eight seconds, not three, and the number is evidence rather than taste. The
# probe rides the same SSH master as the desktop's pixels: measured quiet,
# ousmousa answers in 0.61s median and 1.57s worst against claude-box's 0.11s
# and 0.38s. Three seconds gave the slower link two lengths of headroom and the
# watcher tore down a live session every time a frame burst ate one, 173 times
# in four days across both machines.
contains "$common_code" 'DESK_PROBE_TIMEOUT:-8' "the ceiling has room for the slower of the two links"

# A tunnel is declared dead by several failures, never by one. The asymmetry is
# the argument: a missed real failure costs six seconds, a false alarm costs the
# session you were working in, plus a TOTP code on the machine that has 2FA.
contains "$tunnel_src" 'DESK_PROBE_TRIES:-3' "one failed probe is not a dead tunnel"
contains "$tunnel_src" 'Not rebuilding' "a probe that misses and recovers is logged, not swallowed"
# `continue 2` was the first shape and it was wrong: it jumped past the two
# checks below it, so a link missing one probe a minute would never reach the
# six-hour ceiling and never notice a dead clipboard bridge. A recovered probe
# has to fall through the rest of the body like any other tick.
lacks "$tunnel_code" 'continue 2' "a recovered probe does not skip the checks below it"
contains "$tunnel_code" 'recovered=1' "a recovered probe falls through to the ceiling and the bridge check"

# The clipboard is checked every minute, not every five. Five minutes of a
# silently dead bridge is five minutes of copying into a void.
contains "$tunnel_src" 'DESK_BRIDGE_EVERY:-4' "a dead clipboard bridge is noticed within about a minute"

# --- the agent watches, it does not tick --------------------------------------
#
# It was RunAtLoad plus a five-minute StartInterval, and that is what made the
# setup feel unreliable. A wifi handoff, a sleep or a VPN switch takes the
# forward with it, and the port is then gone for up to five minutes while the
# box itself is perfectly healthy. Windows App says the PC is offline, which is
# true and useless. Worse, no interval can catch a tunnel that is listening and
# dead, because from the outside that looks exactly like a working one.
contains "$tunnel_src" '<key>KeepAlive</key><true/>' "the agent is restarted whenever it exits"
contains "$tunnel_src" '<string>--watch</string>' "the agent runs the watcher, not a one-shot"
# The comments still name it, because the comment explaining a mistake is
# allowed to name it. The code is what must not.
lacks "$tunnel_code" 'StartInterval' "the five-minute interval is gone"
contains "$tunnel_src" 'desk_forward_healthy' "the watcher checks the same thing the client will ask"

# Both ceilings. The watcher is meant to be long-lived, not immortal: a process
# alive since the last reboot is one nobody has proved still works.
contains "$tunnel_src" 'DESK_WATCH_MAX_LIFE:-21600' "the watcher hands back to launchd after six hours"

# The backoff exists because launchd restarts a KeepAlive job as fast as
# ThrottleInterval allows, and every restart against ousmousa spends a TOTP code
# at the login prompt. A box switched off for an hour would burn 120 of them.
contains "$tunnel_src" '"$wait" -gt 600' "a host that is simply off is retried at most every ten minutes"
contains "$tunnel_code" "printf '0' > \"\$FAIL_FILE\"" "a tunnel that came up and dropped is rebuilt at once, not after a penalty"

# ...and the hold has to end when its reason does. An outage drove the counter
# to five, the network came back two minutes later, and the tunnel stayed down
# for the remaining eight minutes of a penalty aimed at a box that was off. The
# box was not off. Ask before serving the sentence.
contains "$tunnel_src" 'desk_host_reachable' "a long hold is cut short once the far host answers again"

# Every exit says why. Removing the backoff trap once the tunnel was up left the
# whole watching phase silent, so a run could end and be restarted with nothing
# in the log at all. Two watchers did exactly that, and the only evidence left
# was launchd's run counter.
contains "$tunnel_src" 'trap _log_exit EXIT' "a run that ends explains itself, even when it succeeds"
contains "$tunnel_src" '_log_signal SIGTERM' "a run killed by a signal says so rather than vanishing"
lacks "$tunnel_code" 'trap - EXIT' "no phase of the run is left without a trap"
contains "$common_code" 'desk_host_reachable()' "the reachability question has its own function"
host_code="$(awk '/^desk_host_reachable\(\)/,/^}/' "$ROOT/lib/common.sh")"
contains "$host_code" 'ssh -G' "the real hostname comes from ssh's resolved config, not a guess"
contains "$host_code" 'nc -z -w 5' "asking whether a host is there is bounded too"

# --- the clipboard bridge survives an outage ----------------------------------
#
# Installing the agent used to run once, above the retry loop, and a single
# failed round trip ended the bridge for good: "giving up", return 1, with a
# ten-try backoff sitting unused a few lines below. A thirty-second drop was
# enough, and the clipboard then stayed dead until a person noticed by hand.
# Comments stripped, for the same reason the tunnel's are: a comment explaining
# a mistake is allowed to name it, the code is what must not.
clip_main="$(awk '/^def main\(\)/,0' "$ROOT/bin/desk-clip" | grep -v '^[[:space:]]*#')"
lacks "$clip_main" 'could not install the remote agent, giving up' "one failed install no longer ends the bridge"
contains "$clip_main" 'if not install_agent():' "installing the agent is retried like everything else"
install_in_loop="$(awk '/while failures < MAX_CONSECUTIVE_FAILURES/,0' "$ROOT/bin/desk-clip")"
contains "$install_in_loop" 'install_agent()' "the install happens inside the retry loop, not before it"

# --- the clipboard rides out an outage ---------------------------------------
#
# Ten tries three seconds apart is thirty seconds of patience, and a wifi
# handoff outlives that. The bridge gave up during an outage the rest of the
# system survived, and the clipboard was then silently gone until someone ran
# desk-tunnel by hand. Found exactly that way: desk-doctor said no bridge, on a
# machine where everything else passed.
clip_src="$(cat "$ROOT/bin/desk-clip")"
contains "$clip_src" 'RETRY_WAIT_MAX' "the reconnect wait grows instead of staying at three seconds"
contains "$clip_src" 'min(RETRY_WAIT * (2 ** n), RETRY_WAIT_MAX)' "it doubles, with a ceiling"

# --- the doctor asks about the tunnel itself ---------------------------------
#
# Every check passed on the evening this section was written, the server was up,
# the session was alive, and the client said the PC was offline. It was right.
# Nothing was listening on the port, and "is the tunnel up" was a question the
# doctor did not ask.
contains "$doctor_src" 'head_ "Tunnel"' "desk-doctor has a section for the tunnel"
contains "$doctor_src" 'is the old five-minute interval agent' "it catches an agent left in the old shape"
contains "$doctor_src" 'desk_rdp_probe' "it proves the port carries RDP, not merely that it is open"

# --- files cross as bytes, and arrive as a uri-list --------------------------
#
# The clipboard cannot carry a file the way it carries text: what sits on the
# Mac pasteboard is a path on THIS machine, which means nothing on the far side.
# So the bytes go over the SSH master and the session's clipboard is given the
# paths they landed at, as text/uri-list, which is what a file manager and an
# Electron app actually read.
clip_src="$(cat "$ROOT/bin/desk-clip")"
contains "$clip_src" 'def send_files' "desk-clip copies files rather than their paths"
contains "$clip_src" 'COPYFILE_DISABLE' "the copy leaves macOS resource forks behind"
contains "$clip_src" 'tail -n +21 | xargs -r rm -rf' "old drops are pruned, so copying does not fill the home directory"
agent_src="$(cat "$ROOT/remote/clip-agent.py")"
contains "$agent_src" 'text/uri-list' "the agent offers files as a uri-list"
pbio_src="$(cat "$ROOT/mac/pbio.swift")"
contains "$pbio_src" 'types.contains(.fileURL)' "the pasteboard reader recognises files"
# Order matters: copying a picture in Finder puts a file url AND a preview image
# on the pasteboard, and answering "image" there loses the file.
files_first="$(awk '/func pasteboardKind/,/^}/' "$ROOT/mac/pbio.swift" | grep -n 'fileURL\|\.png' | head -1)"
case "$files_first" in *fileURL*) ok "files are checked before images" ;;
                       *) bad "images are checked first, so a copied picture file loses its path" ;; esac
