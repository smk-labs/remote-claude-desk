# Why the connection looks like this

Every flag in `bin/desk` is there because the obvious alternative broke
something. This page is the reasoning, written down so nobody simplifies a flag
back out.

## Colour depth is 32, never 24

At 24 bits a pixel is 3 bytes, which does not match xrdp's 4 byte framebuffer.
The stride slips and the screen tears into vertical stripes.

- `/bpp:32`, which is what xrdp renders natively, so it is also the cheapest
- 16 also works and is cheaper on bandwidth, but it dithers antialiased text
- `DESK_BPP=16 desk` if bandwidth ever matters more than readability
- 24 is not a supported choice here. It is the stripes

## The desktop size never changes

xrdp 0.9.24 cannot survive a live resize. The moment the size changes it re-runs
capability exchange, and the next frame kills the connection.

- symptom: `UPDATE_TYPE Bitmap [1] failed`, then the link drops
- confirmed with RemoteFX on and off, so it is not the codec
- so `/dynamic-resolution` is out and `/size` is fixed, default `1920x1080`
- `/smart-sizing` scales that fixed desktop to whatever the window is. The
  window stays resizable, the green button works and fullscreen works, while the
  server never learns the size changed
- cost: the picture is scaled unless the window is exactly `DESK_SIZE`
- `DESK_SIZE=2560x1600 desk` matches a different monitor for a 1:1 picture

## RemoteFX is on

The codec is on because the path it replaces is the one that dies.

- `/rfx`. The server advertises codec id 3
- without it, updates take the legacy bitmap PDU path, and that is the path that
  fails after a resize
- turning the codec off was once blamed for a bug it did not cause. See
  [lessons.md](lessons.md)
- EGFX stays off by default. xrdp 0.9.24 supports it only partly, so
  `DESK_GFX=1 desk` is for once a plain session is known clean

## One session, never two

XFCE cannot start twice for one user, so a second session dies instantly and
takes the client down with it.

- `Policy=UBI` in `sesman.ini` reuses the session when user, colour depth and
  client IP all match
- `X11DisplayOffset=150` keeps our displays clear of other tenants on a shared
  box, several of whom run `Xvfb -ac` with X access control switched off
- both are set by the server installer. See [../server/README.md](../server/README.md)
- the same floor is `DESK_DISPLAY_MIN` on the Mac side, and both the launcher
  and `desk_remote_display` refuse anything below it

## Windowed by default

Starting fullscreen made macOS build and destroy a Space, which is the flash you
see at launch. FreeRDP builds its window three times per launch regardless.

- `DESK_FULL=1 desk` starts fullscreen
- `SDL_VIDEO_MAC_FULLSCREEN_SPACES` is 1 by default, so fullscreen gets its own
  Space, a three-finger swipe reaches it and the green button works
- `DESK_SPACES=0 desk` stays on the current desktop. No flash, but no Space

## Sound off, drive on, password on stdin

Three smaller choices that are easy to get wrong.

- `-sound -microphone` is the correct way to disable them. `/sound:off` is not a
  key FreeRDP knows, so it fails quietly
- `/drive:mac,$DESK_SHARE` is how files cross, since the bridge carries text only
- the password comes from the macOS Keychain and is fed to FreeRDP on stdin with
  `/from-stdin:force`, so it never appears in `ps` or in a file
- `/cert:ignore /sec:rdp`, because the tunnel is the security boundary here. The
  listener is on loopback on the server and reachable only through SSH
