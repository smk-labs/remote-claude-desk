# Keyboard and clipboard

Typing and pasting in the remote desktop behave the way they do on the Mac.
Mac text navigation works, a second keyboard layout works, one key switches
language, and a copied image pastes. Outside that one window the Mac is
unchanged.

Run `desk-tunnel` and the keyboard half is applied for you. The clipboard half
now lives entirely on the server.

## Three problems, three homes

These are independent problems, so they also fail independently. Knowing which
fix lives where is the point of this page.

| Problem | Fix lives in |
| --- | --- |
| Text keys (Home, End, word jump), Cmd+Q, Cmd+W, Fn | `mac/karabiner-rules.json` |
| No second layout, no language key | `remote/apply-layout.sh`, pushed per connection by `desk-tunnel` |
| Text pastes, an image never does | `remote/clip-png.sh`, running inside the session |

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

Text crosses on xrdp's own clipboard channel, which is Windows App's clipboard
talking to `xrdp-chansrv`. Nothing on the Mac is involved.

This used to be a pair of processes over the SSH master, because the channel as
FreeRDP drove it dropped every non-ASCII item silently. That bridge was deleted
on 2026-09-05 with the rest of the client layer. The measurements that justified
it are kept in [lessons.md](lessons.md).

### Images need one shim on the server

The channel hands an image to X as `image/bmp` and nothing else. Chromium,
Electron and GTK ask for `image/png` and ignore BMP, so a paste looks like
nothing happening at all: the cursor blinks and the app moves on, because the
format it wanted was never offered.

Measured on a live session, xrdp 0.10.1:

```
TARGETS        -> TARGETS TIMESTAMP MULTIPLE image/bmp
image/png      -> 0 bytes
image/bmp      -> 15286 bytes, "PC bitmap, Windows 3.x, 68 x 56 x 32"
```

- `remote/clip-png.sh` watches the clipboard, converts a BMP-only offer with
  ImageMagick, and re-offers it as PNG
- it runs inside the session from an autostart entry. `server/install.sh` does
  not write that entry, so it is set up on the box by hand
- it cannot feed itself: once PNG is on the clipboard the BMP is gone with it,
  so the condition is false and nothing is converted twice
- it needs `xclip` and ImageMagick on the server. `desk-doctor` checks both
- on xrdp 0.9.24 the same read produced a **truncated** BMP that ImageMagick
  refused with "length and filesize do not match", so this shim could not have
  worked then. It works because the bytes finally arrive whole on 0.10, which is
  one of the two reasons that version floor is not negotiable
