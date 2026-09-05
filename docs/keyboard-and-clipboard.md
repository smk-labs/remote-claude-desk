# Keyboard and clipboard

Typing and pasting in the remote desktop behave the way they do on the Mac.
Mac text navigation works, a second keyboard layout works, one key switches
language, and a copied image pastes. Outside that one window the Mac is
unchanged.

Run `desk-tunnel` and both halves are applied for you. It pushes the keyboard
layout into the session and starts the clipboard bridge.

## Three problems, three homes

These are independent problems, so they also fail independently. Knowing which
fix lives where is the point of this page.

| Problem | Fix lives in |
| --- | --- |
| Text keys (Home, End, word jump), Cmd+Q, Cmd+W, Fn | `mac/karabiner-rules.json` |
| No second layout, no language key | `remote/apply-layout.sh`, pushed per connection by `desk-tunnel` |
| The clipboard carries nothing, and the client hangs after a screenshot | `bin/desk-clip`, started by `desk-tunnel`, with RDP's own clipboard turned off |

Symptom first? Start at [troubleshooting.md](troubleshooting.md).

## The Command key

Nothing in this repo remaps Cmd any more. The old FreeRDP client did it with a
`/kbd:remap` flag, and that flag went with the client on 2026-09-05. Windows App
does its own modifier handling.

So if a Cmd shortcut inside the session does not do what you expect, the answer
is either in the client's own keyboard settings or in a Karabiner rule. It is
not here.

## Karabiner

Mac muscle memory, translated to the Windows and Linux equivalents, but only
while the remote desktop window is in front.

- three rules, in `mac/karabiner-rules.json`, copied by `mac/install.sh` into
  `~/.config/karabiner/assets/complex_modifications/`
- rule names: `9 Essential Mac Navigation Keys to Windows`,
  `RDP: Cmd+Q to Alt+F4 and Cmd+W to Ctrl+W`,
  `Fn to Shift+Option (Win) and F18 (Mac)`
- every rule is scoped by bundle identifier: `com.microsoft.rdc.macos`,
  `com.microsoft.rdc.mac`, `com.microsoft.WindowsApp`
- the install script never edits your `karabiner.json`. That file holds every
  device, profile and rule you own, so one bad write costs your whole keyboard
  setup. The assets folder is Karabiner's own import door

The full key table is in [../mac/README.md](../mac/README.md). One open question
about two of these rules is recorded in [lessons.md](lessons.md).

## A second layout, and the language key

The server may already have two layouts configured, but the live X server comes
up with only the first one. So the layout is pushed back on every connect.

- xrdp sets the keymap from what the client announces, and it does that after
  `xfce4-settings` has had its say, so a server-side setting alone loses
- `setxkbmap -layout "$LAYOUTS" -option "$TOGGLE"`, in `remote/apply-layout.sh`
- `desk-tunnel` runs that script over the SSH master, on every connect and every
  five minutes if you installed the LaunchAgent
- bounded: 12 tries, 2 seconds apart, and it wants three consecutive successes
  before believing the answer, because the first one can land while xrdp is
  still writing over it
- nothing is written to any server config. It is per connection, every time
- `desk-tunnel` prints whether the layout landed, and says so plainly when there
  was no session to push into yet. That case is normal on a first connect: run
  it again once you are connected
- switch key: **Fn**, or **Option+Shift** by hand
- set `DESK_LAYOUTS="us"` in `config.sh` if you only want one layout. The toggle
  is then simply unused

There is a second push on the server itself: `/usr/local/bin/xrdp-layout`, run
from `reconnectwm.sh` and from an autostart entry, which covers a session that
comes up without anyone running `desk-tunnel` first. Neither the script nor the
entry is in this repo, and `server/install.sh` does not create them, so on a new
box that is a step you do by hand.

### Why the Fn key has two routes

Fn is wired twice, and either route switches the language.

- route one: the Karabiner rule fires and Fn becomes Shift+Option, which is the
  Windows language switch
- route two: the rule does not fire, Fn arrives as F18 instead, and X keycodes
  191 to 202 (F13 to F24) are bound to `ISO_Next_Group` by `xmodmap`
- that whole range was empty and is unreachable from a Mac keyboard except
  through Karabiner, so claiming all twelve costs nothing and removes the guess
  about which one Fn lands on. Measured: keycode 196 flips the layout
- the second route exists because the first could not be verified against the
  old bundle-less client. Windows App is an ordinary bundled app, so route one
  should now be the reliable one. Route two stays anyway: it is one loop on the
  server, and it has already earned its place once

### The Caps Lock unlatch

`apply-layout.sh` clears a latched Caps Lock on every connect. A lock key can
arrive as a press with no matching release when both ends are remapping
modifiers, which leaves the lock half-applied in the session.

- measured on 2026-09-03: `xset q` said "Caps Lock: on" and "LED mask: 00000001"
  in the session while the Mac's own key was untouched
- it fires only when X itself says the lock is on, so it cannot make anything
  worse
- the old client mirrored the session's LED state onto the Mac keyboard, which
  is what made this baffling to diagnose. Whether Windows App mirrors LEDs the
  same way has not been re-measured

## The clipboard

RDP carries no clipboard at all here. Both directions ride the SSH master
instead, through `bin/desk-clip`, which `desk-tunnel` starts for you.

### Why RDP's own clipboard is off

Windows App deadlocks when an image lands on the Mac pasteboard while the client
is redirecting the clipboard towards the remote side. Taking a macOS screenshot
over the session is enough to trigger it. After that the clipboard carries
nothing, the session refuses to reopen, and only quitting the whole app clears
it.

It is the client's bug, not xrdp's and not this repo's. It has been reported to
Microsoft repeatedly since early 2026, never acknowledged, and is still present
in version 11.4.0. The same people reproduce it against real Windows hosts, and
other RDP clients such as Jump Desktop and Royal TSX do not do it. The published
workaround is to stop using the direction that hangs.

### Turning it off

Two routes, and either one is enough.

- **Per connection.** In Windows App, edit the PC and set the clipboard
  redirection dropdown to off.
- **For every connection.** One line, then quit and reopen the app, because it
  reads the setting at launch:

```sh
defaults write com.microsoft.rdc.macos "ClientSettings.DisableClipboardRedirection" -bool true
```

The app's documented modes are `0` do not redirect, `1` full redirection, `2`
local to remote only, and `3` remote to local only. Mode `3` also avoids the
deadlock, and it is what the public reports recommend, because only the local to
remote direction hangs. With the bridge carrying both directions, `0` loses
nothing.

### What the bridge is

Two processes and one SSH connection. No part of it speaks RDP, which is exactly
why the client cannot deadlock it: the client is not in the path.

- `bin/desk-clip` runs on the Mac. It reads the pasteboard through
  `bin/desk-pbio`, a small Swift binary that `mac/install.sh` builds from
  `mac/pbio.swift`, and sends what it finds down the SSH master as base64. With
  no `desk-pbio` it falls back to `pbpaste`, which speaks text only, so an image
  is invisible to it and cannot cross.
- `remote/clip-agent.py` runs in the session. It owns the X CLIPBOARD selection
  through `xclip`, offering `UTF8_STRING` for text and `image/png` for a
  picture, and it reports back when something else in the session copies.
- `desk-tunnel` starts one bridge per machine, in the background, and says what
  it did on its `Clipboard:` line. With no session there is nothing to attach
  to, exactly as with the keyboard: connect, then run `desk-tunnel` again. The
  five-minute re-run replaces a bridge that died and leaves a live one alone.
- Neither helper is on your PATH. Both are found next to `desk-tunnel` rather
  than typed, so `DESK_COMMANDS` in `lib/common.sh` still lists only
  `desk-doctor` and `desk-tunnel`. `desk-pbio` is built rather than committed,
  so a fresh clone does not have it until you run the installer.
- Anything over 2 MB is skipped and logged rather than sent. The log is
  `~/.cache/remote-claude-desk/clip.log`.

### What crosses, measured

Text goes both ways. An image goes from the Mac into the session. An image does
not come back: the remote agent watches the X selection for text only, so a
picture copied inside the session stays there.

Measured end to end against a live session, md5 taken at both ends:

| What | Direction | Size | md5 |
| --- | --- | --- | --- |
| Persian text | Mac to remote | 17 bytes | `a6cb75cf5976d4ff5ea11482de732745` |
| A 64x64 PNG | Mac to remote | 7858 bytes | `3486e6569259b2271b08348a1f31074e` |
| Persian text | remote to Mac | 31 bytes | `0e3e50efb88eb5ec6d95e92bdae9c55b` |

Every one was byte-identical at both ends. Trap 17 in [lessons.md](lessons.md)
is about the measurement itself, which was wrong before it was right.

### The BMP shim is dormant, not gone

`remote/clip-png.sh` watches the clipboard, converts a BMP-only offer with
ImageMagick, and re-offers it as PNG. It was written for the RDP channel, which
hands X an image as `image/bmp` and nothing else, while Chromium, Electron and
GTK ask for `image/png` and ignore BMP.

The bridge does not need it. An image sent over SSH is offered as `image/png`
already, which is the format those apps request, so on this path there is
nothing to convert. The script stays, unused, for anyone who turns the RDP
channel back on. `desk-doctor` still checks that it and ImageMagick are present.
