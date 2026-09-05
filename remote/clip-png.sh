#!/usr/bin/env bash
# Re-offer a BMP-only clipboard as PNG, inside an xrdp session.
#
# Why this exists. xrdp's clipboard channel hands an image to X as image/bmp and
# nothing else. Chromium, Electron and GTK ask for image/png and ignore BMP, so
# a pasted image looks like nothing happening at all: the cursor blinks and the
# app moves on, because the format it wanted was never offered.
#
# Measured on a live session, xrdp 0.10.1:
#   TARGETS        -> TARGETS TIMESTAMP MULTIPLE image/bmp
#   image/png      -> 0 bytes
#   image/bmp      -> 15286 bytes, "PC bitmap, Windows 3.x, 68 x 56 x 32"
#
# On xrdp 0.9.24 the same read produced a TRUNCATED bmp that ImageMagick refused
# with "length and filesize do not match", so this shim could not have worked
# then. It works now because the bytes finally arrive whole. That is why the
# version check in remote/check.sh matters to this file too.
#
# The loop cannot feed itself: once PNG is on the clipboard the BMP is gone with
# it, so the condition below is false and nothing is converted twice.
set -u

command -v xclip >/dev/null || { echo "xclip missing" >&2; exit 1; }
command -v convert >/dev/null || { echo "ImageMagick missing" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -n "${owner:-}" ] && kill "$owner" 2>/dev/null; exit 0' EXIT INT TERM
owner=""

while :; do
  targets="$(timeout 5 xclip -selection clipboard -t TARGETS -o 2>/dev/null || true)"
  case "$targets" in
    *image/png*) : ;;                      # already usable, leave it alone
    *image/bmp*)
      if timeout 5 xclip -selection clipboard -t image/bmp -o > "$tmp/in.bmp" 2>/dev/null \
         && [ -s "$tmp/in.bmp" ] \
         && convert "$tmp/in.bmp" png:"$tmp/out.png" 2>/dev/null \
         && [ -s "$tmp/out.png" ]; then
        # Replace the previous owner we started, so these cannot pile up.
        [ -n "$owner" ] && kill "$owner" 2>/dev/null
        xclip -selection clipboard -t image/png -i "$tmp/out.png" >/dev/null 2>&1 &
        owner=$!
      fi ;;
  esac
  sleep 0.3
done
