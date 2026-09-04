# The remote scripts are real code and must be checked like it.
#
# This file is the whole reason remote/ exists. 227 lines used to live inside
# heredocs and a Python r-string, where a hard syntax error passed both
# `bash -n` and `shellcheck -x` without a word. Now every one of them is parsed
# on every test run.
# shellcheck shell=bash

for f in "$ROOT"/remote/*.sh; do
  name="remote/$(basename "$f")"
  if bash -n "$f" 2>/dev/null; then ok "$name parses"; else bad "$name has a syntax error"; fi
done

for f in "$ROOT"/remote/*.py; do
  name="remote/$(basename "$f")"
  if python3 -m py_compile "$f" 2>/dev/null; then ok "$name parses"
  else bad "$name has a syntax error"; fi
done
rm -rf "$ROOT/remote/__pycache__"

if command -v shellcheck >/dev/null 2>&1; then
  for f in "$ROOT"/remote/*.sh; do
    name="remote/$(basename "$f")"
    n="$(shellcheck -S warning "$f" 2>&1 | grep -cE '\(warning\)|\(error\)')"
    is "$n" "0" "$name is shellcheck clean"
  done
else
  ok "shellcheck not installed, skipped (syntax was still checked)"
fi

# The scripts read their input from the environment, never from values pasted
# into them, which is what desk_remote_run relies on to stay injection-safe.
contains "$(cat "$ROOT/remote/find-display.sh")" '$MIN' "find-display.sh reads MIN from the environment"
contains "$(cat "$ROOT/remote/apply-layout.sh")" '$LAYOUTS' "apply-layout.sh reads LAYOUTS from the environment"
contains "$(cat "$ROOT/remote/check.sh")" '$MIN' "check.sh reads MIN from the environment"

# No payload may be re-embedded as a string literal. This is the regression
# guard for the finding that started the whole refactor.
for f in "$ROOT"/bin/* "$ROOT"/lib/*.sh; do
  name="$(basename "$f")"
  if grep -q "<<'REMOTE" "$f" 2>/dev/null || grep -q "^REMOTE_AGENT = r'''" "$f" 2>/dev/null; then
    bad "$name has re-embedded a remote payload as a string literal"
  fi
done
ok "no remote payload is embedded as a string literal"

# --- a latched Caps Lock is cleared, because the symptom shows up on the Mac --
# FreeRDP mirrors this X server's LED state onto the client keyboard, so a Caps
# Lock stuck on here lights the lamp on a Mac whose own key is off. The guard
# matters as much as the fix: firing unconditionally would toggle the lock ON
# for anyone who had it deliberately off.
layout="$(cat "$ROOT/remote/apply-layout.sh")"
contains "$layout" 'Caps Lock: *on' \
         "apply-layout only unlatches when X itself says the lock is on"
contains "$layout" 'xdotool key --clearmodifiers Caps_Lock' \
         "apply-layout clears a latched Caps Lock"


# The framebuffer is priced on the server, so the server is what has to judge
# it: xrdp encodes every frame in software. A doctor that cannot see DESK_SIZE
# reports a green box that cannot draw the desktop it was asked for.
contains "$(cat "$ROOT/remote/check.sh")" '${SIZE:-}' "check.sh reads SIZE from the environment"
contains "$(cat "$ROOT/bin/desk-doctor")" 'SIZE=${DESK_SIZE:-' "desk-doctor sends DESK_SIZE to the server checks"
