#!/usr/bin/env bash
# Push the keyboard layout into the live X session, and confirm it stuck.
#
# Run on the server by desk_remote_run, with DISP, LAYOUTS and TOGGLE in the
# environment. Exits 0 only when the layout is actually loaded.
#
# This has to happen per connection and cannot be done once on the server.
# xfconf may already say what you want, but the live X server comes up as plain
# "us": xrdp sets the keymap from what the client announces, and it does that
# after xfce4-settings has had its say. Nothing here is written to any server
# config, so the next session comes up exactly as it did before.
#
# This file used to be a quoted string inside bin/desk, where $HOME, $k and the
# closing $ of the grep pattern all needed backslashes to survive two levels of
# quoting. That is the entire reason it is a file now: as a file it is just
# shell, and shellcheck can see it.
set -u

export DISPLAY="$DISP"
export XAUTHORITY="$HOME/.Xauthority"

setxkbmap -layout "$LAYOUTS" -option '' -option "$TOGGLE" 2>/dev/null

# The language key. On a Mac the Fn/globe key is the input switcher, and a
# Karabiner rule turns it into Shift+Option inside a remote desktop. That rule
# is scoped by application, and matching an application with no bundle id is
# the one part of this that cannot be checked from the Mac side. So F13 to F24
# are bound as a second, independent route: when the Karabiner rule does not
# fire, Fn arrives as F18 instead.
#
# All twelve keycodes are empty and unreachable from a Mac keyboard except
# through Karabiner, so claiming the whole range costs nothing and removes the
# guess about which one Fn lands on. Measured: keycode 196 flips the layout.
for k in $(seq 191 202); do
  xmodmap -e "keycode $k = ISO_Next_Group" 2>/dev/null
done

# Confirm, rather than assume. The caller retries until this passes several
# times in a row, because the first success can land while xrdp is still
# writing over the keymap.
setxkbmap -query | grep -q "^layout: *${LAYOUTS}$"
