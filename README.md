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

## The problem it actually solves

Point any RDP client at a stock xrdp box from a Mac and you get this. None of it
announces itself, which is what makes it expensive.

| What you see | What it really is |
|---|---|
| Cmd+C, Cmd+V, Cmd+A do nothing | macOS sends Cmd as Super, which Linux ignores for copy and paste |
| Persian, Arabic, Chinese, emoji paste as nothing at all | the RDP clipboard channel carries ASCII and silently drops the rest |
| The client quits a few seconds after connecting | a session outlived the sesman that tracked it and is now untracked forever |
| Vertical stripes across the screen | 24-bit colour, whose stride does not match xrdp's 4-byte framebuffer |
| The connection dies right after you resize the window | xrdp cannot survive a live desktop resize |
| Shift+Enter toggles fullscreen instead of reaching the app | the client's own shortcuts default to a Right Shift modifier |
| Home, End, word jump, Cmd+Q, Cmd+W all wrong | Mac text navigation has no equivalent on Linux |
| Every TLS connection fails | Ubuntu ships the xrdp user outside the `ssl-cert` group, so it cannot read its own key |

Each row is one fix in this repo, and
[docs/troubleshooting.md](docs/troubleshooting.md) is the symptom-first version
of the same table.

## Quick start

Three commands on the Mac, one on the server.

```bash
git clone https://github.com/smk-labs/remote-claude-desk.git
cd remote-claude-desk && ./mac/install.sh
cp config.example.sh config.sh && $EDITOR config.sh
```

Set `DESK_HOST` and `DESK_USER` in `config.sh`. Then, on the Linux box:

```bash
./server/install.sh --user me
```

Store the Linux password once, check everything, and connect:

```bash
desk-setup && desk-doctor && desk
```

`desk-doctor` is the important one. It checks about thirty preconditions across
both machines and names the cause instead of leaving you to guess.

## The daily command

```bash
desk
```

That is it. It brings the SSH master up if it is down, heals an orphaned session
if it finds one, forwards the port, pushes your keyboard layout into the live X
session, starts the clipboard bridge, and opens the window.

| Command | What it does |
|---|---|
| `desk` | connect |
| `desk --stop` | disconnect |
| `desk-doctor` | check every precondition on both machines |
| `desk-setup` | store the Linux password in the macOS Keychain |
| `desk-tunnel` | forward the port only, for a native RDP client |

Per-run overrides live in `desk --help`. Machine settings live in `config.sh`.

## Recommended alongside

The always-on box is only worth having if it has work to do while you are away.
Two things make that real.

- **A task manager.** Queue work so the box is busy when you are not watching.
  Without one, an always-on machine is just a machine that is on.
- **[claude-desktop-relay](https://github.com/smk-labs/claude-desktop-relay)**,
  if you hold more than one Claude subscription. It decides which of your own
  accounts pays for a session, so hitting a limit on one does not stop the work.
  It runs on the same box, behind the same desktop.

Neither is required. `desk` does not know or care whether either is installed.

## How it is laid out

One config file, one shared library, and five small commands. Everything that
used to be copied into four scripts now lives in exactly one place.

```
config.example.sh   the only file you edit
lib/common.sh       config, SSH, display discovery, safe remote kill
bin/                desk, desk-clip, desk-doctor, desk-setup, desk-tunnel
mac/                install.sh, Karabiner rules, FreeRDP shortcut override
server/             install.sh, the orphan reaper, the listener lock, the
                    isolated Claude Desktop launcher
bar/                optional macOS menu bar app
docs/               why each setting is what it is, and how it was measured
```

## Requirements

Nothing exotic on either end, and no daemon is added to your Mac.

- **Mac:** macOS 13 or later, `brew install freerdp` (the SDL client, so XQuartz
  is not needed), python3, and optionally Karabiner-Elements for the Mac keys
- **Server:** Ubuntu 22.04 or 24.04, xrdp with xorgxrdp, XFCE, `xclip`,
  `setxkbmap`, `xmodmap`, python3
- **Between them:** SSH key access, and a `~/.ssh/config` entry with
  `ControlMaster auto` so one connection is reused

## Security

The desktop is never exposed to the internet. It listens on a loopback address
only, and you reach it through the SSH connection you already trust.

- xrdp binds `127.0.0.77:33890`, not `0.0.0.0:3389`
- an iptables OWNER rule limits even that to one uid, so other tenants on a
  shared box are refused
- the RDP password sits in the macOS Keychain and is handed to FreeRDP on stdin,
  so it never appears in `ps`, in a file, or in shell history
- on a shared box, the display floor and an ownership check stop the session
  ever attaching to another user's screen

## Undo

Both installers have a matching uninstaller, and neither deletes your data.

```bash
./mac/uninstall.sh          # symlinks, FreeRDP override, Karabiner asset
./server/uninstall.sh       # restores every config from a timestamped backup
```

## Reading further

- [docs/troubleshooting.md](docs/troubleshooting.md) start here when something breaks
- [docs/keyboard-and-clipboard.md](docs/keyboard-and-clipboard.md) the four keyboard and clipboard fixes, and where each one lives
- [docs/why-these-settings.md](docs/why-these-settings.md) why each connection flag is there, so nobody simplifies it back
- [docs/isolation.md](docs/isolation.md) keeping the remote Claude Desktop away from a central `~/.claude`
- [docs/lessons.md](docs/lessons.md) how every claim here was measured, which diagnoses were wrong, and what is still unverified
- [mac/README.md](mac/README.md) and [server/README.md](server/README.md) what each installer touches

`docs/lessons.md` is the one worth reading even if you never run any of this.
Most of the work was not writing the code, it was finding out which of the
obvious tools were lying.

## Licence

MIT. See [LICENSE](LICENSE).
