# The words this repo uses

Read this before changing anything. Most confusion here comes from two things
having similar names and completely different lifetimes.

## The nouns

- **The master** is the multiplexed SSH connection, held open at
  `DESK_SSH_SOCKET`. Everything else rides it: the port forward, the clipboard
  bridge, the layout push, every check `desk-doctor` runs. One connection, many
  users of it.
- **The session** is the XFCE desktop on the server, owned by `xrdp-sesman`. It
  outlives the client completely. Closing the window is like switching off a
  monitor, and reconnecting returns to the same desktop. Only a server reboot
  ends it.
- **The client** is `sdl-freerdp` on the Mac, which lives exactly as long as the
  window is open.
- **The display** is the X display number the session runs on, such as `:150`.
  It is discovered per connection, never assumed. See `desk_remote_display`.
- **The bridge** is `desk-clip`, a pair of processes (one on each machine) that
  carries text between the two clipboards over the master. It exists because the
  RDP clipboard channel drops anything that is not ASCII.
- **An orphan** is a session whose `xrdp-sesman` was restarted underneath it.
  The desktop keeps running but nothing tracks it any more, and every later
  connect makes a new session that dies at once.

## The lifetimes, which are all different

This is the part worth internalising. A thing that looks stuck is usually a
thing whose lifetime you guessed wrong.

| Thing | Ends when |
|---|---|
| The client | you close the window |
| The bridge | the client exits (`desk` stops it) |
| The master | it is idle past `ControlPersist`, or you kill it |
| The session | the server reboots |
| An orphan | something kills it by hand |

## Where a setting belongs

Three homes, and putting a value in the wrong one is the usual mistake.

- **`config.sh`** for anything true of the machine: host, user, ports, the
  display floor, the keyboard layouts. Read once at startup by every command.
- **An environment variable** for anything true of one run only: `DESK_SIZE`,
  `DESK_BPP`, `DESK_FULL`. Listed in `desk --help`.
- **`lib/common.sh`** for behaviour, never for values. If two commands need the
  same logic, it goes here, and it goes here as a function so no caller can
  forget the part that bites.

## The rule behind most of the code

Anything that can fail silently gets a check and a message. That is not a style
preference, it is what the whole of `docs/lessons.md` is about: in this system
almost every real bug was invisible rather than loud. A clipboard that stopped
crossing, a layout pushed at a display that was not there, a bridge that never
started. All of them looked like a working desktop.

So: bound every wait, name every failure, and prefer a check that says "this is
off" over a default that quietly does nothing.
