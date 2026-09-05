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
- **A remote script** is a file in `remote/` that runs on the server, not on
  the Mac. There are five: find the display, heal an orphan, push the layout,
  run the server checks, and the clipboard agent. They reach the server one way
  only, through `desk_remote_run`, which sends the file over the master and
  passes values as environment assignments in front of the interpreter. They
  used to be text inside the commands, where no parser could read them.
- **The lock** is `desk-<local port>.pid` in the cache directory, one per
  machine, holding the pid of the desk that owns that machine. It is what makes
  two desks side by side normal and two desks on one machine impossible. An
  xrdp session has one seat, so two clients on it take it from each other
  forever; two different machines share nothing and run happily at once.
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
| The lock | the desk holding it exits, or another desk takes the machine |
| The master | it is idle past `ControlPersist`, or you kill it |
| The session | the server reboots |
| An orphan | something kills it by hand |

## Where a setting belongs

Four homes, and putting a value in the wrong one is the usual mistake.

- **`config.sh`** for anything true of the machine: host, user, ports, the
  display floor, the keyboard layouts. Read once at startup by every command.
  It is sourced, so everything in it runs, and `desk_load_config` refuses a copy
  that group or others can write to.
- **An environment variable** for anything true of one run only: `DESK_SIZE`,
  `DESK_BPP`, `DESK_FULL`. Listed in `desk --help`.
- **`lib/`** for behaviour, never for values, and split by kind. `common.sh`
  does things: load the config, hold the SSH master, retry with a ceiling, kill
  safely on the far side. `freerdp-args.sh` decides one thing, the client's
  argv, and touches no network, which is what lets `test/run` check it. If two
  commands need the same logic it goes here as a function, so no caller can
  forget the part that bites.
- **`remote/`** for anything that executes on the server. A remote script reads
  its input from the environment and never has values pasted into it. Nothing
  else may run code on the far side, and `test/test-remote-scripts.sh` fails if
  a payload is embedded in a command again.

## The rule behind most of the code

Anything that can fail silently gets a check and a message. That is not a style
preference, it is what the whole of `docs/lessons.md` is about: in this system
almost every real bug was invisible rather than loud. A clipboard that stopped
crossing, a layout pushed at a display that was not there, a bridge that never
started. All of them looked like a working desktop.

So: bound every wait, name every failure, and prefer a check that says "this is
off" over a default that quietly does nothing. Keep code where a parser can read
it too, because a script hidden in a string is the same silence one level down.
