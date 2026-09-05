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

# The two xrdp version traps, both hit on a live box in one evening.
#
# Scrolling: before xorgxrdp 0.10 the driver made a wheel click per RDP packet
# instead of accumulating the delta. Measured with a passive grab on the root
# window: median 46 events per trackpad flick, 138 a second. A real wheel sends
# three to ten. No Mac-side setting can touch it, because both the system scroll
# slider and a per-app scroll tool change the delta, which that driver never reads.
#
# Display range: xrdp 0.10 added MaxDisplayNumber, default 63, and a server with
# an offset of 150 then fails every connect with a message the client renders as
# "No X displays are available", which sounds like the box is full.
check_src="$(cat "$ROOT/remote/check.sh")"
contains "$check_src" 'xorgxrdp_v="$(dpkg-query -W' "check.sh reads the xorgxrdp version"
contains "$check_src" 'MaxDisplayNumber' "check.sh compares the display offset against the cap"

# The clipboard image shim. xrdp hands X an image as image/bmp and nothing else,
# and Chromium, Electron and GTK all ask for image/png, so a paste looks like
# nothing happening. It converts and re-offers, and it cannot feed itself
# because PNG replaces the BMP rather than joining it.
clip_png="$(cat "$ROOT/remote/clip-png.sh")"
contains "$clip_png" 'image/bmp' "clip-png reads the BMP xrdp actually offers"
contains "$clip_png" 'xclip -selection clipboard -t image/png -i' "clip-png re-offers it as PNG"
