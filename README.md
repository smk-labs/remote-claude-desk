# remote-claude-desk

Claude Desktop lives on an always-on Linux box. Your Mac is just the screen.

Close the lid, lose the wifi, walk to a cafe, reboot the laptop. The agent
session does not notice, because it was never running on the laptop. You
reconnect and the window is exactly where you left it, mid-task.

That is the whole idea. Everything in this repo exists because getting there is
harder than it sounds: a Linux desktop viewed from a Mac is close to unusable
out of the box, and the reasons are all small, silent, and separately annoying.

## Why not just run it locally

A local Claude Desktop is tied to the machine you carry. That is fine until a
long agent run meets a closed lid. A remote one is tied to a box that never
sleeps, so the run is decoupled from your day.

- long tasks keep going while the laptop is shut, asleep, or on a plane
- the machine that does the work has a stable IP and stays on one network
- your laptop's battery, fans and memory are not part of the job
- one cheap VM can hold several sessions, and you reach them from anywhere

## What it is not

Not a way to share one Claude subscription between people, and not a hosting
product. It connects your Mac to your own Linux box over your own SSH.

It also does not install Claude Desktop for you, and it works perfectly well
with no Claude anywhere: what it really ships is a Linux desktop from a Mac that
behaves the way a Mac user expects.

It is not an RDP client either, and no longer tries to be. You connect with
Microsoft's Windows App, which keeps its own saved credentials and its own
keyboard handling. Its clipboard is the one part you switch off: it deadlocks
the app, so the clipboard travels over SSH instead. This repo used to drive
FreeRDP's SDL client; that client froze, macOS recorded where, and the whole
client layer was deleted on 2026-09-05. The measurements are in
[docs/lessons.md](docs/lessons.md), trap 11.

## Why the Mac still has a job

One job, and it is the one thing that cannot move to the server.

xrdp there listens on `127.0.0.77:33890`, never on `0.0.0.0:3389`, so the
desktop is not reachable over the network at all. An SSH tunnel is the only way
in, and a tunnel has to be built from the machine you are sitting at. That is
what `desk-tunnel` does.

While it is there, it does three more things that also have to happen from this
side. It brings the SSH master up. It clears an orphaned session before that
session kills your next connect. It pushes your keyboard layout into the live X
session, because xrdp sets the keymap from what the client announces and every
session otherwise comes up as plain `us`.

Then a fourth: it starts the clipboard bridge. Windows App's own clipboard has
to stay off, because it deadlocks the app, so `desk-clip` carries both
directions over the SSH master instead. Why, and how to turn the client's off,
is in [docs/keyboard-and-clipboard.md](docs/keyboard-and-clipboard.md).

## The problem it actually solves

Point any RDP client at a stock xrdp box from a Mac and you get this. None of it
announces itself, which is what makes it expensive.

| What you see | What it really is |
|---|---|
| The client quits a few seconds after connecting | a session outlived the sesman that tracked it, so every later connect starts a new one that dies at once |
| Persian, or any second layout, does not exist in the session, and the Fn key does nothing | xrdp sets the session keymap from what the client announces, after `xfce4-settings` has had its say |
| A trackpad flick scrolls a whole page | xorgxrdp before 0.10 made a full wheel click out of every RDP packet instead of accumulating the delta |
| Every login fails with "No X displays are available" after an xrdp upgrade | xrdp 0.10 caps display numbers at 63 by default, and this setup puts them at 150 |
| You take a screenshot, and afterwards the clipboard carries nothing and the session will not reopen | Windows App deadlocks when an image reaches the Mac pasteboard while it is redirecting the clipboard towards the remote side. A Microsoft bug, unfixed as of 11.4.0 |
| Home, End, word jump, Cmd+Q, Cmd+W all wrong | Mac text navigation has no equivalent on Linux |
| Every TLS connection fails | Ubuntu ships the `xrdp` user outside the `ssl-cert` group, so it cannot read its own key |
| Anyone else on the box can reach your login prompt | xrdp's default listener is `0.0.0.0:3389`, open to the machine and to the internet |

Each row is one fix in this repo, and
[docs/troubleshooting.md](docs/troubleshooting.md) is the symptom-first version
of the same table.

## Quick start

Three lines on the Mac, one on the server.

```bash
git clone https://github.com/smk-labs/remote-claude-desk.git
cd remote-claude-desk && ./mac/install.sh
cp config.example.sh config.sh && $EDITOR config.sh
```

Set `DESK_HOST` and `DESK_USER` in `config.sh`. Then, on the Linux box:

```bash
sudo ./server/install.sh --user me
```

Check both ends, then open the tunnel:

```bash
desk-doctor && desk-tunnel
```

`desk-doctor` is the important one. It checks about forty preconditions across
both machines and names the cause instead of leaving you to guess.

`desk-tunnel` prints what to type into your RDP client when it is done. In
Windows App, add a PC with:

| Field | Value |
|---|---|
| PC name | `localhost:33890`, or whatever `DESK_LOCAL_PORT` says |
| User account | your `DESK_USER` and its Linux password |
| Folders | add `~/RemoteShare` to get the shared drive |
| Clipboard | set redirection to off. It deadlocks the app, and `desk-clip` carries the clipboard over SSH instead |

Windows App saves the password itself, so nothing here stores one.

One line turns it off for every connection at once instead. Quit and reopen the
app afterwards, because it reads the setting at launch.

```bash
defaults write com.microsoft.rdc.macos "ClientSettings.DisableClipboardRedirection" -bool true
```

## The daily command

```bash
desk-tunnel --install
```

Run that once per Mac and you never type anything again. It writes a LaunchAgent
named after this machine that runs `desk-tunnel` at login and every five
minutes: that is what rebuilds a master dropped by a wifi handoff, what pushes
the layout into a session that did not exist when you logged in, and what
replaces a clipboard bridge that died. Every step inside is idempotent, so a
re-run on a healthy setup is a few cheap checks.

| Command | What it does |
|---|---|
| `desk-tunnel` | open the tunnel, heal an orphan, push the layout, start the clipboard bridge, once |
| `desk-tunnel --install` | do that at login and every 5 minutes, for this machine |
| `desk-tunnel --uninstall` | stop doing that |
| `desk-doctor` | check every precondition on both machines |
| `desk-doctor --local` | skip the checks that need the server |

Machine settings live in `config.sh`. `DESK_CONFIG` names a different file, which
is how one Mac drives two boxes.

## Recommended alongside

The always-on box is only worth having if it has work to do while you are away.
Two things make that real.

- **A task manager.** Queue work so the box is busy when you are not watching.
  Without one, an always-on machine is just a machine that is on.
- **[claude-desktop-relay](https://github.com/smk-labs/claude-desktop-relay)**,
  if you hold more than one Claude subscription. It decides which of your own
  accounts pays for a session, so hitting a limit on one does not stop the work.
  It runs on the same box, behind the same desktop.

Neither is required. Nothing here knows or cares whether either is installed.

## How it is laid out

One config file, two commands, and code split by which machine runs it.

```
config.example.sh     the only file you edit
lib/common.sh         config, SSH, display discovery, safe remote kill, retry
bin/                  desk-tunnel, desk-doctor, and the two clipboard helpers
                      that sit beside them
remote/               the seven scripts that run on the server
test/                 run, plus the checks it runs
mac/                  install.sh, uninstall.sh, the Karabiner rules, the
                      pasteboard reader
server/               install.sh, the orphan reaper, the listener lock, the
                      isolated Claude Desktop launcher
docs/                 how each fix was measured, and which diagnoses were wrong
```

- `bin/` holds four files but only two commands. `desk-clip` and `desk-pbio` are
  started by `desk-tunnel` and found next to it, never typed, so `DESK_COMMANDS`
  in `lib/common.sh` keeps them off your PATH. `desk-pbio` is built by
  `mac/install.sh` from `mac/pbio.swift` rather than committed
- `remote/` holds every line that executes on the server. One function,
  `desk_remote_run` in `lib/common.sh`, sends a script over the SSH master and
  runs it there. Those scripts used to be text inside the commands, where no
  parser ever read them (see [docs/lessons.md](docs/lessons.md), trap 8)
- `lib/common.sh` is behaviour, never values: load the config, hold the master,
  retry with a ceiling, kill safely on the far side. If two commands need the
  same logic it goes here, so no caller can forget the part that bites

### Before you send a change

Run the tests first. They need a Mac and nothing else.

```bash
test/run
```

- 59 checks in about a second. No server, no SSH, no window
- they cover the shared library, the config guard, and that every script in
  `remote/` still parses and is shellcheck clean

## Requirements

Nothing exotic on either end, and no daemon is added to your Mac beyond the
optional LaunchAgent.

- **Mac:** macOS 13 or later, Microsoft's Windows App, and optionally
  Karabiner-Elements for the Mac keys. `nc` and `ssh` ship with macOS. The Xcode
  command line tools (`xcode-select --install`) supply the `python3` that runs
  `desk-clip` and the `swiftc` that builds `bin/desk-pbio`. Without `desk-pbio`
  the clipboard still carries text, but not images
- **Server:** Ubuntu 22.04 or 24.04, XFCE, `xclip`, ImageMagick, `setxkbmap`,
  `xmodmap`, `python3`. `xclip` is what the clipboard agent owns the X selection
  with. ImageMagick is only for `remote/clip-png.sh`, which is dormant while the
  RDP clipboard is off
- **xrdp 0.10 or later, with xorgxrdp 0.10 or later.** Not optional. On 0.9.x a
  trackpad flick scrolls about ten times too far, and no Mac-side setting can
  change it
- **Between them:** SSH key access, and a `~/.ssh/config` entry with
  `ControlMaster auto` so one connection is reused

Ubuntu 24.04 ships xrdp 0.9.24. The 25.04 pair, xrdp 0.10.1 with xorgxrdp
0.10.2, installs cleanly on it: every dependency resolves and the Xorg ABIs
match. After that upgrade you must raise `MaxDisplayNumber` in `sesman.ini`,
which 0.10 defaults to 63, below the display offset of 150. Miss it and every
login fails with "No X displays are available". `desk-doctor` compares the two
numbers and says so.

## Security

The desktop is never exposed to the internet. It listens on a loopback address
only, and you reach it through the SSH connection you already trust.

- xrdp binds `127.0.0.77:33890`, not `0.0.0.0:3389`
- an iptables OWNER rule limits even that to one uid, so other tenants on a
  shared box are refused
- nothing here stores your Linux password. Windows App keeps its own saved
  credentials, in its own store
- `desk_load_config` refuses a `config.sh` that group or others can write to. The
  file is sourced, so everything in it runs
- on a shared box, the display floor and an ownership check stop the session
  ever attaching to another user's screen

## Undo

Both installers have a matching uninstaller, and neither deletes your data.

```bash
desk-tunnel --uninstall     # the LaunchAgent, on this Mac
./mac/uninstall.sh          # the ~/bin symlinks and the Karabiner asset
./server/uninstall.sh       # restores every config from a timestamped backup
```

## Reading further

- [docs/troubleshooting.md](docs/troubleshooting.md) start here when something breaks
- [docs/keyboard-and-clipboard.md](docs/keyboard-and-clipboard.md) the keyboard and clipboard fixes, and where each one lives
- [docs/isolation.md](docs/isolation.md) keeping the remote Claude Desktop away from a central `~/.claude`
- [docs/lessons.md](docs/lessons.md) how every claim here was measured, which diagnoses were wrong, and what is still unverified
- [mac/README.md](mac/README.md) and [server/README.md](server/README.md) what each installer touches

`docs/lessons.md` is the one worth reading even if you never run any of this.
Most of the work was not writing the code, it was finding out which of the
obvious tools were lying.

## Licence

MIT. See [LICENSE](LICENSE).
