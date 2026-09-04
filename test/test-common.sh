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

# --- the menu bar app does not trust the login profile for PATH ---------------
# launchd gives Desk.app no PATH to inherit, so its `bash -lc` builds one from
# the profile alone. On a Mac whose only bash login file never mentions ~/bin,
# every row ran `desk` and got "command not found" into a log nobody opens, while
# a terminal test passed because an interactive shell already exports ~/bin.
bar="$(cat "$ROOT/bar/desk-bar.swift")"
contains "$bar" 'PATH=\"$HOME/bin:$PATH\"' \
         "the menu bar app prepends ~/bin rather than trusting the login profile"

# --- the packaged Claude launcher is found by what it runs, not what it is called
# It was looked for as claude-desktop.desktop. The package ships
# com.anthropic.Claude.desktop, so the installer said "nothing to hide" and hid
# nothing, and the menu carried two Claude entries: the isolated one, and one
# click that starts the app against the central ~/.claude. That is the isolation
# intact and trivially bypassable, with nothing on screen saying which is which.
inst="$(cat "$ROOT/server/install.sh")"
lacks "$inst" "/usr/share/applications/claude-desktop.desktop" \
      "the installer does not look for the packaged entry by a guessed filename"

# The pattern must match how the package actually writes it, and must NOT match
# our own launcher, whose name merely starts the same way.
_pat='^Exec=([^ ]*/)?claude-desktop( |$)'
contains "$inst" "$_pat" "the installer matches the packaged entry on its Exec line"
printf 'Exec=claude-desktop %%U\n' | grep -qE "$_pat" \
  && ok "the pattern matches Exec=claude-desktop %U, which is what ships today" \
  || bad "the pattern misses the Exec line the package actually writes"
if printf 'Exec=/home/me/desktop-trial/bin/claude-desktop-isolated %%U\n' | grep -qE "$_pat"; then
  bad "the pattern also matches our own isolated launcher, which it would then hide"
else
  ok "the pattern leaves the isolated launcher alone"
fi

# The shadow must be a stub, not a copy. A copied entry brings the packaged
# Actions with it, and each action is another Exec line starting the
# non-isolated binary, which docks offer from a right-click and some launchers
# surface from search even when the entry is NoDisplay. Hiding the icon while
# leaving two live routes to the thing being hidden is not hiding it.
lacks "$inst" "grep -v '^NoDisplay=' \"\$packaged\"" \
      "the shadow entry is written fresh, not copied from the packaged file"
contains "$inst" "Name=Claude (do not use - not isolated)" \
         "the shadow says what it is, because NoDisplay is a request not a guarantee"

# --- the menu bar reads the process table with a tool that prints argv --------
# `pgrep -f -a` is a GNU extension. BSD pgrep, which is what macOS ships, prints
# bare pids whatever you pass it, so scanning its output for the client's -/v:
# flag matched nothing and every session read as down: no tick anywhere and a
# Disconnect greyed out while a window was open in front of you. It fails
# silently and identically to "nothing is connected".
# The path, not the bare word: the comment above the fix names pgrep in prose,
# and a check that a comment can fail is a check nobody will trust twice.
bar_src="$(cat "$ROOT/bar/desk-bar.swift")"
lacks "$bar_src" "/usr/bin/pgrep" "the menu bar does not run pgrep, which prints no argv on macOS"
contains "$bar_src" "/bin/ps" "the menu bar reads the process table with ps"

# And ps must print arguments here, not just names, or the port cannot be read
# off the line. A full argv has a slash and then a space.
# Captured, then matched with a glob, rather than piped into `grep -q`. Under
# `pipefail` that pipeline reports failure even when the match succeeds: grep
# exits at the first hit, ps is killed by SIGPIPE, and the non-zero from the
# dead ps becomes the status of the whole pipeline. The check then fails while
# what it is checking is perfectly true.
ps_out="$(/bin/ps -Ao command=)"
case "$ps_out" in
  */*\ *) ok "ps -Ao command= prints full argv on this machine" ;;
  *)      bad "ps -Ao command= printed no arguments, so the menu bar cannot see a session" ;;
esac

# --- the menu bar and desk agree on the default local port -------------------
# The bar cannot source a config, so it carries its own copy of the fallback.
# If the two drift, the bar watches a port nothing listens on and the tick and
# the Disconnect quietly disappear for every machine that does not name a port.
swift_default="$(sed -n 's/^let DEFAULT_LOCAL_PORT = "\([0-9]*\)".*/\1/p' "$ROOT/bar/desk-bar.swift" | head -1)"
shell_default="$(sed -n 's/.*DESK_LOCAL_PORT:=\([0-9]*\).*/\1/p' "$ROOT/lib/common.sh" | head -1)"
is "$swift_default" "$shell_default" "the menu bar and desk agree on the default local port"

# --- every command in bin/ is on the list that puts commands on PATH ---------
# The bug this replaces: `desk-setup` shipped, was executable, was the first word
# of the README's own quick start, and was in none of the three copies of the
# list, so nothing ever linked it. Comparing the list against the directory is
# the only check that catches the next one, because a list that is merely
# self-consistent is still wrong when a file is added beside it.
# desk-clip and desk-pbio are both found beside `desk` rather than typed, so
# neither belongs on PATH. desk-pbio is also built rather than committed, so a
# clean checkout does not have it and this list must not require it.
expected="$(cd "$ROOT/bin" && ls | grep -vE '^(desk-clip|desk-pbio)$' | sort | tr '\n' ' ')"
actual="$(printf '%s ' $(printf '%s\n' $DESK_COMMANDS | sort))"
is "$actual" "$expected" "DESK_COMMANDS lists every command in bin/ except desk-clip"

# desk-clip is left out on purpose, and saying so here stops someone "fixing" it.
for helper in desk-clip desk-pbio; do
  case " $DESK_COMMANDS " in
    *" $helper "*) bad "$helper is on PATH, but it is meant to be found next to desk" ;;
    *) ok "$helper is deliberately not on PATH" ;;
  esac
done

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

# --- the pasteboard probe must never fetch the pasteboard -------------------
#
# `pbio kind` is asked ten times a second, forever. It used to answer by
# fetching the contents: imageData() pulled the whole picture out of the
# pasteboard server, and re-encoded a PNG from TIFF when the copy was a
# screenshot, only to throw it away and print the word "image". Ten full copies
# a second out of one shared service is what made every other app on the Mac
# beachball, and it survived the commit that was meant to fix it, because that
# one only stopped the transfer and left the probe alone.
#
# So the guard is on the probe, not on the transfer: the kind branch may read
# the type list and nothing else.
kind_branch="$(awk '/^case "kind":/{f=1;next} /^case /{f=0} f' "$ROOT/mac/pbio.swift")"
lacks "$kind_branch" "imageData()" "pbio kind does not fetch the image"
lacks "$kind_branch" "pb.string(" "pbio kind does not fetch the text"
contains "$(cat "$ROOT/mac/pbio.swift")" "pb.types" "pbio decides the kind from the type list"

# --- the client must not draw through Metal ---------------------------------
#
# Two macOS hang reports, two days apart, two different servers, and every
# sample of the main thread in the same place: SDL_RenderPresent, into
# -[CAMetalLayer nextDrawable], into a semaphore that never came back. The layer
# lends three drawables and the client takes one per flush and returns one per
# frame, so any frame with several damaged rectangles keeps the difference.
# Three of those and the pool is empty for good, the main thread stops, and the
# RDP keepalive stops with it. That is the freeze, start to finish, and none of
# it is on the far side.
desk_src="$(cat "$ROOT/bin/desk")"
contains "$desk_src" 'export SDL_RENDER_DRIVER=' "desk chooses SDL's renderer rather than letting it default"
contains "$desk_src" '${DESK_RENDERER:-opengl}' "desk defaults that renderer to opengl, not metal"

# --- one desk per machine, not one client per machine ------------------------
#
# Ending the previous CLIENT left the desk that owned it running, and that desk
# reconnected, and the two then traded the single seat an xrdp session has for
# as long as the laptop was on. Four of them were found alive at once, three
# orphaned to init, each with its own clipboard bridge.
contains "$desk_src" 'LOCK="$LOGDIR/desk-${DESK_LOCAL_PORT}.pid"' \
         "desk takes a lock named after the machine's own port"
contains "$desk_src" 'kill -TERM "$holder"' "desk ends the previous desk, not just its client"

# --- macOS already knows why the client froze --------------------------------
doctor_src="$(cat "$ROOT/bin/desk-doctor")"
contains "$doctor_src" 'DiagnosticReports/sdl-freerdp*.hang' \
         "desk-doctor reads the hang reports macOS files about the client"
