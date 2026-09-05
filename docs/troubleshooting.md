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
- if you installed the LaunchAgent, every run it makes lands in
  `~/.cache/remote-claude-desk/tunnel-agent.log`, so a failure at login is
  diagnosable without reproducing it

## Symptom table

| What you see | What it actually is | What to do |
| --- | --- | --- |
| You take a screenshot while in the RDP window, and then the clipboard stops working, and the session will not reopen until you quit Windows App entirely | A deadlock inside Windows App, triggered by an image reaching the Mac pasteboard while the client is redirecting the clipboard toward the remote side. Known since early 2026, unacknowledged by Microsoft, still there in 11.4.0, and reproducible against real Windows hosts too | Turn RDP clipboard redirection off, which is the published workaround. `desk-clip` then carries both directions over SSH, where the client is not involved and cannot be deadlocked |
| The client quits a few seconds after connecting. The log says `ERRINFO_LOGOFF_BY_USER` | Nobody logged off. A session outlived the sesman that tracked it, so every new connect starts a second session, which dies at once | Let `desk-tunnel` heal it: it kills any xrdp Xorg older than sesman before it forwards the port, and does it again every five minutes once the LaunchAgent is installed. If it recurs, install the reaper from [../server/README.md](../server/README.md) |
| The window stops repainting and macOS calls the client Not Responding | macOS samples an app that stops servicing its main thread and files a `.hang` report with every thread's stack in it | `desk-doctor` reads the newest report and prints the deepest frame that still names a subsystem. That is how the old FreeRDP client was caught blocking in `-[CAMetalLayer nextDrawable]`, which is why it was removed on 2026-09-05. Two reports sat on the disk for two days first |
| A trackpad flick scrolls a whole page, and nothing on the Mac changes it | xorgxrdp before 0.10 made a full wheel click out of every RDP packet instead of accumulating the delta. Measured on this box with a passive grab: median 46 events per flick, 138 a second, where a real wheel sends 3 to 10. The Mac scroll slider and per-app scroll tools change the delta, which that driver never reads, so both do nothing | Upgrade to xorgxrdp 0.10+ with xrdp 0.10+. `desk-doctor` reports the version and says which side of the fix you are on |
| Every connect fails with "No X displays are available" after an xrdp upgrade | xrdp 0.10 added `MaxDisplayNumber`, default 63. A display offset above it leaves an empty range, and the server log says so plainly: `no display in range (150 to 63)`. The client's message sounds like the box is full instead | Add `MaxDisplayNumber` above your offset to `[Sessions]` in sesman.ini. `desk-doctor` compares the two now |
| Text pastes but an image never does: the cursor blinks and nothing happens | Two different faults, one after the other. On xrdp 0.9.24 the BMP arrived truncated and ImageMagick refused it outright. On 0.10.1 it arrives whole, but the clipboard offers `image/bmp` and nothing else, while Chromium, Electron and GTK all ask for `image/png` | Upgrade to xrdp 0.10+, then run `remote/clip-png.sh` in the session. It converts a BMP-only clipboard to PNG and re-offers it. Give it an autostart entry so it survives a logout: nothing in this repo writes one |
| Having to run `desk-tunnel` before you can work | It does its job and exits by design: it holds nothing open, the SSH master does | `desk-tunnel --install` writes a LaunchAgent per machine: at login, then every 5 minutes. Every step in it is idempotent, so a re-run on a healthy setup is three cheap checks, and a re-run after a wifi drop is the repair |
| Persian does not exist in the session and the Fn key does nothing | Nothing pushed the layout. xrdp sets the session keymap from what the client announces, after xfce4-settings has had its say, so every session comes up as plain `us` whatever the server says | `desk-tunnel` pushes it and prints whether it landed. On a first connect the session may not exist yet, so run it again once connected |
| The tunnel was fine yesterday and today the client cannot reach it | The SSH master survived a network change. It still answers `-O check` while every channel through it is dead, so the forward is accepted and goes nowhere | Nothing to do by hand. `desk_forward` proves the port answers, and tears the master down and rebuilds it once when it does not |
| The server is green in `desk-doctor` but everything is slow | The far side encodes every frame in software, so a wedged process holding a core, or a framebuffer bigger than the cores can encode, shows up as lag | `desk-doctor` reports any process that has averaged 80% of a core, free memory, and the size priced against the core count |
| The keyboard layout will not switch | Either the layout push never landed, or it landed on the wrong X display | See below |
| TLS handshakes fail and the client never gets a login screen | Ubuntu ships the `xrdp` user outside the `ssl-cert` group, so it cannot read its own `/etc/xrdp/key.pem` | `usermod -aG ssl-cert xrdp`. Before this, 70 of 98 error lines in `xrdp.log` were TLS |
| The RDP login is refused whatever you type | The account may have no password at all. `adduser --disabled-password` makes one, and xrdp refuses it every time | `desk-doctor` reads `passwd -S` on the server and says which of the three states the account is in. Fix with `sudo passwd <user>` |
| Claude Desktop asks you to sign in every time | No unlocked secret store in the session, so the app will not keep a session | Install with `--keyring`, which adds `pam_gnome_keyring` to `/etc/pam.d/xrdp-sesman` |
| Claude Desktop cannot reach claude.ai at all | IP reputation on a shared cloud box, not your setup | See below |
| Your work is gone after the server rebooted | The session survives everything except a server reboot | Nothing to fix. Closing the window, losing the network, sleeping the Mac and changing network all reconnect to the same session |

## When the layout will not switch

Two different causes, and they need different answers. `desk-tunnel` prints the
display it found and whether the layout landed, so start there.

- **it landed on the wrong display.** The display used to be hardcoded. When a
  session fails to start, xrdp hands out the next number, and the layout push
  then targets a display that is not there. It is discovered now, by
  `desk_remote_display` in `lib/common.sh`
- **`desk-tunnel` said it could not confirm the layout after 12 tries.** xrdp
  writes over the keymap after `xfce4-settings` does, so the push is retried and
  wants three consecutive successes. If it still fails, check `setxkbmap` and
  `xmodmap` exist on the server
- **it said there was no session to push into.** That is the normal first-run
  answer. Connect with your RDP client, then run `desk-tunnel` again
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
