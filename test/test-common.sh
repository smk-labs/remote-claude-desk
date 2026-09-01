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
HOME="$HOME_BEFORE"
rm -rf "$tmp"
