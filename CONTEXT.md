# The words this repo uses

Read this before changing anything. Most confusion here comes from two things
having similar names and completely different lifetimes.

## The nouns

- **The master** is the multiplexed SSH connection, held open at
  `DESK_SSH_SOCKET`. Everything else rides it: the port forward, the layout
  push, every check `desk-doctor` runs on the server. One connection, many
  users of it.
- **The forward** is the loopback port the RDP client dials, opened on the
  master by `desk_forward`. It is the only reason the Mac has any work to do at
  all: xrdp listens on `127.0.0.77` and nothing else can reach it.
- **The session** is the XFCE desktop on the server, owned by `xrdp-sesman`. It
  outlives the client completely. Closing the window is like switching off a
  monitor, and reconnecting returns to the same desktop. Only a server reboot
  ends it.
- **The client** is Microsoft's Windows App on the Mac, and nothing here starts
  it, stops it or knows whether it is running. It holds its own saved
  credentials and its own keyboard handling. It lives exactly as long as the
  window is open. Its clipboard redirection must be off: an image reaching the
  Mac pasteboard while the client redirects towards the remote side deadlocks
  the app, and only a full quit clears it. See
  [docs/keyboard-and-clipboard.md](docs/keyboard-and-clipboard.md).
- **The bridge** is the pair of processes that carries the clipboard instead:
  `bin/desk-clip` on the Mac and `remote/clip-agent.py` in the session, talking
  over the master. It speaks no RDP at all, which is why the client's deadlock
  cannot reach it. `desk-tunnel` starts one per machine and reports it on a
  `Clipboard:` line. Its log is `~/.cache/remote-claude-desk/clip.log`.
- **The display** is the X display number the session runs on, such as `:150`.
  It is discovered per connection, never assumed. See `desk_remote_display`.
- **A remote script** is a file in `remote/` that runs on the server, not on
  the Mac. There are seven: find the display, heal an orphan, push the layout,
  run the server checks, own the clipboard selection, re-offer a clipboard image
  as PNG, and a scroll probe kept as an instrument. The four a command calls
  reach the server one way only, through `desk_remote_run`, which sends the file
  over the master and passes values as environment assignments in front of the
  interpreter. They used to be text inside the commands, where no parser could
  read them. The other three arrive differently: `desk-clip` copies
  `clip-agent.py` into the remote user's own cache directory and drives it over
  stdin, while `clip-png.sh` and `scroll-probe.py` are put on the box by hand.
- **The LaunchAgent** is `com.smk-labs.desk-tunnel.<host>`, written by
  `desk-tunnel --install`, one per Mac because two boxes are normal here. It
  holds nothing open. It re-runs `desk-tunnel` at login and every five minutes,
  which is what heals a master dropped by a wifi handoff and what pushes the
  layout into a session that did not exist at login. Its log is
  `~/.cache/remote-claude-desk/tunnel-agent.log`.
- **An orphan** is a session whose `xrdp-sesman` was restarted underneath it.
  The desktop keeps running but nothing tracks it any more, and every later
  connect makes a new session that dies at once.

## The lifetimes, which are all different

This is the part worth internalising. A thing that looks stuck is usually a
thing whose lifetime you guessed wrong.

| Thing | Ends when |
|---|---|
| The client | you close the window |
| The forward | the master goes away |
| The bridge | it gives up after 10 failed reconnects, or you kill it. `desk-tunnel` starts a fresh one within five minutes |
| The master | it is idle past `ControlPersist`, or you kill it |
| The LaunchAgent | you run `desk-tunnel --uninstall` |
| The session | the server reboots |
| An orphan | `desk-tunnel` heals it on its next run, or the reaper does when sesman starts |

## Where a setting belongs

Four homes, and putting a value in the wrong one is the usual mistake.

- **`config.sh`** for anything true of the machine: host, user, ports, the
  display floor, the keyboard layouts. Read once at startup by every command.
  It is sourced, so everything in it runs, and `desk_load_config` refuses a copy
  that group or others can write to.
- **An environment variable** for anything true of one run only. `DESK_CONFIG`
  names a different config file, which is how one Mac drives two boxes.
  `DESK_SIZE` is read only by `desk-doctor`, to price the framebuffer against
  the server's core count. Environment variables are also the only way
  `desk-clip` is configured at all: it is Python and cannot source `config.sh`,
  so `DESK_HOST`, `DESK_SSH_SOCKET` and `DESK_DISPLAY` reach it as exported
  variables, and it refuses to start if any of the three is empty.
- **`lib/common.sh`** for behaviour, never for values: load the config, hold the
  SSH master, retry with a ceiling, discover the display, kill safely on the far
  side. If two commands need the same logic it goes here as a function, so no
  caller can forget the part that bites.
- **`remote/`** for anything that executes on the server. A remote script reads
  its input from the environment and never has values pasted into it. Nothing
  else may run code on the far side, and `test/test-remote-scripts.sh` fails if
  a payload is embedded in a command again.

## The rule behind most of the code

Anything that can fail silently gets a check and a message. That is not a style
preference, it is what the whole of `docs/lessons.md` is about: in this system
almost every real bug was invisible rather than loud. A layout pushed at a
display that was not there, an image that pasted as nothing, a session nothing
was tracking. All of them looked like a working desktop.

So: bound every wait, name every failure, and prefer a check that says "this is
off" over a default that quietly does nothing. Keep code where a parser can read
it too, because a script hidden in a string is the same silence one level down.
