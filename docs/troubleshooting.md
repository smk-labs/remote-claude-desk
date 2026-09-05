# Troubleshooting

## Run desk-doctor first

Almost every failure here looks the same from the outside: a window that does
not open, or one that opens and quits. `desk-doctor` walks the whole chain and
names the link that is broken.

```sh
desk-doctor           # check the Mac, the SSH master and the server
desk-doctor --local   # skip the checks that need the server
```

- it exits non-zero when something is broken, so it also works in a script
- every check below is a check it already makes, and most are a bug that really
  happened
- every run of `desk` also appends to `~/.cache/remote-claude-desk/last.log`, so
  a failure is diagnosable without reproducing it

## Symptom table

| What you see | What it actually is | What to do |
| --- | --- | --- |
| The client quits a few seconds after connecting. The log says `ERRINFO_LOGOFF_BY_USER` | Nobody logged off. A session outlived the sesman that tracked it, so every new connect starts a second session, which dies at once | Let `desk` heal it: its preflight kills any xrdp Xorg older than sesman. If it recurs, install the reaper from [../server/README.md](../server/README.md) |
| The window opens, then the pointer becomes a spinner, macOS calls the client Not Responding, and the connection times out | SDL's Metal renderer. The client asks `CAMetalLayer` for a drawable on every flush and returns one per frame, so a frame with several damaged rectangles, which is any scroll, leaks the rest. Three leaks empty the pool and `nextDrawable` blocks for good | Fixed: `desk` runs SDL on OpenGL, which has no drawable pool. `DESK_RENDERER=metal` puts it back if you want to test a newer SDL. `desk-doctor` also reads macOS's own hang reports now and names the frame it stopped in |
| Persian does not exist in the session and the Fn key does nothing, using a native client | Nothing pushed the layout. xrdp sets the session keymap from what the client announces, after xfce4-settings has had its say, so every session comes up as plain `us` whatever the server says | `desk-tunnel` pushes it now and prints whether it landed. On a first connect the session may not exist yet, so run it again once connected |
| The window is Not Responding under load, but macOS filed no hang report | Priority, not a deadlock. A desk started from a background context runs niced, and a niced client does not fail, it falls behind. A real deadlock always leaves a `.hang` report; this leaves none | `desk` says so at startup and `desk-doctor` reports the client's nice. Nothing can lower it without root: quit and start from the menu bar app or a terminal |
| The desktop keeps disconnecting a few seconds after it connects, over and over | Two `desk` processes. An xrdp session is one seat, so each one's client takes it from the other, and both reconnect. Ending the client was never enough: the desk that owned it just opened another | Fixed: one pid file per machine, and a new `desk` ends the old one before it starts. `desk-doctor` warns when more desks are running than hold a lock |
| The server is green in `desk-doctor` but everything is slow | Not the same fault as the freeze above. The far side encodes every frame in software, so a wedged process holding a core, or a `DESK_SIZE` bigger than the cores can encode, shows up as lag | `desk-doctor` reports any process that has averaged 80% of a core, free memory, and the size priced against the core count |
| The whole Mac stutters while a screenshot sits on the pasteboard | Fixed. `pbio kind` used to fetch the picture ten times a second to answer a question about its type, so every app queued behind the pasteboard server | Nothing to do. `test/test-common.sh` fails if the probe reads contents again |
| Vertical stripes across the screen | 24 bit colour. The stride does not match xrdp's 4 byte framebuffer | Use `/bpp:32`, the default. Never 24. See [why-these-settings.md](why-these-settings.md) |
| The connection dies immediately after you resize the window | xrdp 0.9.24 cannot survive a live resize. The log says `UPDATE_TYPE Bitmap [1] failed` | Nothing to fix. The size is fixed and `/smart-sizing` scales it. Do not add `/dynamic-resolution` |
| Cmd+C, Cmd+V and Cmd+A do nothing inside the session | macOS sends Cmd as Super, and Linux ignores Super for copy and paste | Leave `DESK_CMD` at 1, so `desk` remaps Super to Left Ctrl inside the connection |
| ASCII pastes fine, anything else arrives empty | The RDP clipboard channel drops non-ASCII silently. 54 bytes in, 0 bytes out | Use the bridge, which is the default. `DESK_CLIP=rdp` is what turns it off |
| Nothing pastes at all, in either direction | The bridge never started, and the RDP channel is off by design, so text has no path | `desk` now warns when `bin/desk-clip` is missing. Run `desk-doctor`, then `mac/install.sh` |
| Shift+Enter toggles fullscreen instead of reaching the app | FreeRDP's SDL client owns its own shortcuts, and their modifier defaults to Right Shift | Install `~/.config/freerdp/sdl-freerdp.json`, which moves them onto Right Shift plus Right Alt plus Right Ctrl |
| The keyboard layout will not switch | Either the layout push never landed, or it landed on the wrong X display | See below |
| TLS handshakes fail and the client never gets a login screen | Ubuntu ships the `xrdp` user outside the `ssl-cert` group, so it cannot read its own `/etc/xrdp/key.pem` | `usermod -aG ssl-cert xrdp`. Before this, 70 of 98 error lines in `xrdp.log` were TLS |
| Claude Desktop asks you to sign in every time | No unlocked secret store in the session, so the app will not keep a session | Install with `--keyring`, which adds `pam_gnome_keyring` to `/etc/pam.d/xrdp-sesman` |
| Claude Desktop cannot reach claude.ai at all | IP reputation on a shared cloud box, not your setup | See below |
| Your work is gone after the server rebooted | The session survives everything except a server reboot | Nothing to fix. Closing the window, losing the network, sleeping the Mac and changing network all reconnect to the same session |

## When the layout will not switch

Two different causes, and they need different answers. `desk` prints the display
it found, so start there.

- **it landed on the wrong display.** The display used to be hardcoded. When a
  session fails to start, xrdp hands out the next number, and the layout push
  then targets a display that is not there. It is discovered now, by
  `desk_remote_display` in `lib/common.sh`
- **`desk` said it could not confirm the layout after 12 tries.** xrdp writes
  over the keymap after `xfce4-settings` does, so the push is retried and wants
  three consecutive successes. If it still fails, check `setxkbmap` and
  `xmodmap` exist on the server
- **the switch key does nothing.** Try Option+Shift by hand first. If that works
  and Fn does not, the Karabiner rule is not firing, and the F18 fallback route
  is what should catch it. See
  [keyboard-and-clipboard.md](keyboard-and-clipboard.md)
- **do not test a layout with `xdotool`.** It reports success whether or not the
  layout is loaded. [lessons.md](lessons.md) explains why

## When claude.ai refuses the connection

A datacenter IP can be refused by claude.ai on IP reputation, before the browser
is ever consulted. This is a constraint anyone on a shared cloud box may hit,
not a bug in this setup.

- measured on one such box: `claude.ai` returned **403** five times out of five
- the same 403 with a full browser User-Agent, so it is not fingerprinting
- `cloudflare.com` and `example.com` both returned 200 from the same box, so
  neither egress nor Cloudflare in general is the problem
- `api.anthropic.com/v1/models` returned **401**, meaning reachable
- consequence: the Cloudflare checkbox can never pass, so a fresh Claude Desktop
  login cannot complete while this holds. Clicking it is wasted effort
- Claude Code against `api.anthropic.com` is unaffected and keeps working
- a shared datacenter address picking up an automation reputation is the likely
  cause. Other tenants on that box ran Chrome with `--remote-debugging-port`
- these blocks are usually temporary. No workaround was attempted, deliberately

## Two things you should not do

Both of these turn a small problem into a long evening.

- **Never restart `xrdp-sesman` while a session is live.** Sesman keeps its
  session list in memory, so the session becomes untracked forever and every
  later connect dies at once. Disconnect first, every time. Both server scripts
  detect a live session and refuse. Restarting `xrdp` alone is safe: it drops
  the connection, not the session
- **Never attach to a display below the floor.** On a shared box other tenants
  run `Xvfb -ac`, with X access control off, so a stray `DISPLAY` opens your app
  on a stranger's screen. The launcher and `desk_remote_display` both refuse a
  display below `DESK_DISPLAY_MIN` or not owned by you
