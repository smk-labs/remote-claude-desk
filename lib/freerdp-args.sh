# shellcheck shell=bash
# Build the FreeRDP command line. Pure: config and environment in, argv out.
#
# It is a separate file because it is the only part of `desk` that can be
# checked without a server, a Keychain item and a window on screen. It used to
# sit in the middle of the connect flow, next to the SSH master and the port
# forward, which meant the question "does DESK_BPP=16 really produce /bpp:16"
# could only be answered by connecting and looking. These flags carry the most
# hard-won knowledge in the project, so they were also the least verifiable
# thing in it. See test/test-args.sh.
#
# Every flag here is present because the obvious alternative broke something.
# docs/why-these-settings.md is the long reasoning.

# Fill the array named DESK_ARGS with the client's argv.
#
# Reads: DESK_LOCAL_PORT, DESK_USER, DESK_SHARE (config) and the per-run
# environment variables listed in `desk --help`. Writes nothing else and
# touches no network.
desk_build_args() {
  DESK_ARGS=()

  # The clipboard channel. NOT a downgrade: the RDP clipboard carries ASCII and
  # silently drops everything else. Measured against a live session, reading the
  # pasteboard through NSPasteboard so no shell locale could lie about it:
  # ASCII 21 bytes crossed exactly, Persian 54 bytes arrived as 0 bytes, and the
  # next ASCII crossed again, so the channel was not wedged. FreeRDP logs it
  # itself at those moments: "ClipboardGetData: No synthesizer for format
  # CF_RAW --> text/plain". /clipboard: has no encoding option, so there is
  # nothing to tune.
  #
  # Text rides the SSH master instead, through desk-clip. Leaving the channel on
  # as well is not an option: xrdp-chansrv and the bridge both want to own the X
  # CLIPBOARD selection, and chansrv wins often enough to hand back the broken
  # copy at random. One owner or none.
  local clip_arg="-clipboard"
  [ "${DESK_CLIP:-bridge}" = "rdp" ] && clip_arg="+clipboard"

  DESK_ARGS+=(
    /v:127.0.0.1:"$DESK_LOCAL_PORT" /u:"$DESK_USER"
    /cert:ignore /sec:rdp
    "$clip_arg"
    /drive:mac,"$DESK_SHARE"
    -sound -microphone        # the correct way to disable; /sound:off is not a
                              # key FreeRDP knows, and it fails silently
    /rfx                      # RemoteFX. The server advertises codec id 3.
                              # Without it, updates take the legacy bitmap PDU
                              # path, and that is what dies after a resize:
                              # "UPDATE_TYPE Bitmap [1] failed" kills the link.
    /log-level:INFO
  )

  # Sizing. The hard constraint is that xrdp 0.9.24 CANNOT survive a live
  # desktop resize: the moment the size changes it re-runs capability exchange
  # and the next frame dies, taking the connection with it. Confirmed with
  # RemoteFX on and off, so it is not the codec.
  #
  # So the desktop size is fixed and never renegotiated. /smart-sizing makes the
  # client scale that fixed desktop to whatever the window is, which keeps the
  # window resizable, the green button working and fullscreen working, while the
  # server never learns the size changed.
  DESK_ARGS+=( /size:"${DESK_SIZE:-1920x1080}" /smart-sizing )
  [ "${DESK_FULL:-0}" = "1" ] && DESK_ARGS+=( /f )

  # Colour depth. MUST be 16 or 32, never 24: at 3 bytes per pixel the stride
  # does not match xrdp's 4-byte framebuffer and the screen tears into vertical
  # stripes. 32 is what xrdp renders natively, so it is also the cheapest.
  DESK_ARGS+=( /bpp:"${DESK_BPP:-32}" )

  [ -n "${DESK_GDI:-}" ] && DESK_ARGS+=( /gdi:"$DESK_GDI" )

  # Command key. macOS sends Cmd as the Super key, which Linux ignores for copy
  # and paste, so without this Cmd+C does nothing at all. The scancodes are not
  # a guess: `sdl-freerdp /list:kbd-scancode` gives 0x15b VK_LWIN, 0x15c VK_RWIN
  # and 0x1d VK_LCONTROL.
  #
  # Doing it here and not in Karabiner is deliberate, for two reasons. It cannot
  # leak out of this connection, so the Mac is untouched everywhere else. And it
  # is downstream of everything, so it also catches a paste that another tool
  # synthesises as a CGEvent, which a Karabiner rule never sees.
  #
  # What it costs: the session never receives Super at all, so XFCE's Super
  # shortcuts are gone. Ctrl on the Mac keyboard still works.
  [ "${DESK_CMD:-1}" = "1" ] && DESK_ARGS+=( /kbd:remap:0x15b=0x1d,remap:0x15c=0x1d )

  # EGFX, off by default. xrdp 0.9.24's support is partial, so turn it on only
  # once a plain session is known clean.
  [ "${DESK_GFX:-0}" = "1" ] && DESK_ARGS+=( /gfx:progressive )

  # Tuning, added only when asked, so a crash here is attributable.
  if [ "${RDP_TUNE:-0}" = "1" ]; then
    DESK_ARGS+=( /compression-level:2 /network:broadband
                 -wallpaper -themes -menu-anims -window-drag )
  fi

  return 0
}
