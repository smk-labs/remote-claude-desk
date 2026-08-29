# The FreeRDP command line. Every assertion here is a rule that used to live
# only in a comment, where nothing could enforce it.
# shellcheck shell=bash

# shellcheck source=../lib/freerdp-args.sh
. "$ROOT/lib/freerdp-args.sh"

# Minimum config the builder reads. Deliberately not a real host: if any of this
# ever touches the network, these values make it fail loudly rather than connect.
DESK_LOCAL_PORT=33890
DESK_USER=testuser
DESK_SHARE=/tmp/test-share

# Build with a clean environment and return the argv as one string.
build() {
  local assignments=("$@")
  ( unset DESK_SIZE DESK_FULL DESK_BPP DESK_CMD DESK_CLIP DESK_GFX DESK_GDI RDP_TUNE
    for a in "${assignments[@]:-}"; do [ -n "$a" ] && export "${a?}"; done
    desk_build_args
    printf '%s' "${DESK_ARGS[*]}" )
}

out="$(build)"

# --- the defaults ------------------------------------------------------------
contains "$out" "/v:127.0.0.1:33890" "connects to the forwarded local port"
contains "$out" "/u:testuser" "uses the configured user"
contains "$out" "/drive:mac,/tmp/test-share" "shares the configured folder"
contains "$out" "/smart-sizing" "smart-sizing is always on, so the window can resize"
contains "$out" "/rfx" "RemoteFX is on, so updates avoid the legacy bitmap path"

# --- the rule that must never be broken --------------------------------------
# 24 bits is 3 bytes per pixel, which does not match xrdp's 4-byte framebuffer.
# The stride slips and the screen tears into vertical stripes.
is "$(build DESK_BPP=32 | grep -o '/bpp:[0-9]*')" "/bpp:32" "default colour depth is 32"
is "$(build DESK_BPP=16 | grep -o '/bpp:[0-9]*')" "/bpp:16" "DESK_BPP=16 is honoured"
lacks "$out" "/bpp:24" "never 24-bit, at any setting"

# --- the size is fixed, never renegotiated -----------------------------------
# xrdp 0.9.24 cannot survive a live desktop resize.
contains "$out" "/size:1920x1080" "a default size is always set"
contains "$(build DESK_SIZE=2560x1600)" "/size:2560x1600" "DESK_SIZE is honoured"
lacks "$out" "/dynamic-resolution" "dynamic resolution is never sent"

# --- the clipboard channel ---------------------------------------------------
# It carries ASCII and silently drops everything else, so it is off and text
# rides the SSH bridge instead. Two owners of the X selection race, so it is
# one or the other, never both.
contains "$out" "-clipboard" "the RDP clipboard channel is off by default"
contains "$(build DESK_CLIP=rdp)" "+clipboard" "DESK_CLIP=rdp turns the channel back on"
lacks "$(build DESK_CLIP=rdp)" "-clipboard" "the two clipboard modes are exclusive"

# --- the Command key ---------------------------------------------------------
# macOS sends Cmd as Super, which Linux ignores for copy and paste.
contains "$out" "/kbd:remap:0x15b=0x1d,remap:0x15c=0x1d" "both Cmd keys map to Left Ctrl"
lacks "$(build DESK_CMD=0)" "/kbd:remap" "DESK_CMD=0 sends Super through untouched"

# --- opt-in flags stay opt-in ------------------------------------------------
lacks "$out" "/f" "windowed by default, so macOS does not build a Space at launch"
contains "$(build DESK_FULL=1)" "/f" "DESK_FULL=1 starts fullscreen"
lacks "$out" "/gfx:progressive" "EGFX is off by default, its support is partial"
contains "$(build DESK_GFX=1)" "/gfx:progressive" "DESK_GFX=1 enables EGFX"
lacks "$out" "-wallpaper" "tuning flags are off unless asked for"
contains "$(build RDP_TUNE=1)" "-wallpaper" "RDP_TUNE=1 adds the tuning flags"

# --- audio -------------------------------------------------------------------
# /sound:off is not a key FreeRDP knows, and it fails silently.
contains "$out" "-sound" "sound is disabled the way FreeRDP understands"
lacks "$out" "/sound:off" "never the form that fails silently"

# --- the password is never an argument ---------------------------------------
lacks "$out" "/p:" "no password ever appears in the argv, so ps cannot show it"
