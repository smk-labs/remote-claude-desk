# Keyboard and clipboard

Typing and pasting in the remote desktop behave the way they do on the Mac.
Command keys work, a second keyboard layout works, one key switches language,
and the clipboard carries non-ASCII text both ways. Outside that one window the
Mac is unchanged.

Run `desk` and all of this is applied for you.

## Four problems, four homes

These are four independent problems, so they also fail independently. Knowing
which fix lives where is the point of this page.

| Problem | Fix lives in |
| --- | --- |
| Cmd+C, Cmd+V, Cmd+A, Cmd+Z do nothing | a FreeRDP flag in `bin/desk` |
| Text keys (Home, End, word jump), Cmd+Q, Cmd+W, Fn | `mac/karabiner-rules.json` |
| No second layout, no language key | `setxkbmap` and `xmodmap`, pushed per connection by `bin/desk` |
| Non-ASCII text is dropped | `bin/desk-clip`, over the SSH master |
| Shift+Enter toggles fullscreen | `~/.config/freerdp/sdl-freerdp.json` |

Symptom first? Start at [troubleshooting.md](troubleshooting.md).

## The Command key

macOS sends Cmd as the Super key, and Linux ignores Super for copy and paste.
`desk` remaps it to Left Ctrl inside the connection only.

- flag: `/kbd:remap:0x15b=0x1d,remap:0x15c=0x1d`, on by default
- the scancodes are not a guess. `sdl-freerdp /list:kbd-scancode` gives `0x15b`
  VK_LWIN, `0x15c` VK_RWIN, `0x1d` VK_LCONTROL
- `DESK_CMD=0 desk` sends Super through untouched
- cost: the session never receives Super, so XFCE's Super shortcuts (the whisker
  menu) are gone. Ctrl on the Mac keyboard still works

It sits in the client and not in Karabiner for two reasons. It cannot leak out
of this connection, so the Mac is untouched everywhere else. And it is
downstream of everything, so it also catches a paste that another tool
synthesises as a CGEvent, which a Karabiner rule never sees.

## Karabiner

Mac muscle memory, translated to the Windows and Linux equivalents, but only
while the remote desktop window is in front.

- three rules, in `mac/karabiner-rules.json`, copied by `mac/install.sh` into
  `~/.config/karabiner/assets/complex_modifications/`
- rule names: `9 Essential Mac Navigation Keys to Windows`,
  `RDP: Cmd+Q to Alt+F4 and Cmd+W to Ctrl+W`,
  `Fn to Shift+Option (Win) and F18 (Mac)`
- each `frontmost_application_if` block carries `"file_paths": ["sdl-freerdp"]`
  beside its existing `bundle_identifiers`
- `bundle_identifiers` alone could never match. `sdl-freerdp` is a bare binary
  with no app bundle, so `NSRunningApplication.bundleIdentifier` is nil for it
- the install script never edits your `karabiner.json`. That file holds every
  device, profile and rule you own, so one bad write costs your whole keyboard
  setup. The assets folder is Karabiner's own import door

The full key table is in [../mac/README.md](../mac/README.md). One open question
about two of these rules is recorded in [lessons.md](lessons.md).

## A second layout, and the language key

The server may already have two layouts configured, but the live X server comes
up with only the first one. So `desk` pushes both back on every connect.

- xrdp sets the keymap from what the client announces, and it does that after
  `xfce4-settings` has had its say, so a server-side setting alone loses
- `setxkbmap -layout "$DESK_LAYOUTS" -option "$DESK_LAYOUT_TOGGLE"`, in
  `apply_layout` in `bin/desk`
- bounded: 12 tries, 2 seconds apart, and it wants three consecutive successes
  before believing the answer, because the first one can land while xrdp is
  still writing over it
- nothing is written to any server config. It is per connection, every time
- switch key: **Fn**, or **Option+Shift** by hand
- set `DESK_LAYOUTS="us"` in `config.sh` if you only want one layout. The toggle
  is then simply unused

### Why the Fn key has two routes

Fn is wired twice on purpose, because the first route cannot be verified from
here. Either one switches the language.

- route one: the Karabiner rule fires and Fn becomes Shift+Option, which is the
  Windows language switch
- route two: the rule does not fire, Fn arrives as F18 instead, and X keycodes
  191 to 202 (F13 to F24) are bound to `ISO_Next_Group` by `xmodmap`
- that whole range was empty and is unreachable from a Mac keyboard except
  through Karabiner, so claiming all twelve costs nothing and removes the guess
  about which one Fn lands on
- the reason for the second route: `file_paths` matching for a bundle-less
  binary is reasoned, not measured. See [lessons.md](lessons.md)

## The clipboard

The RDP clipboard channel carries ASCII and silently drops everything else, so
text rides the SSH tunnel instead.

Measured against a live session, reading the pasteboard through NSPasteboard so
no shell locale could lie about it:

- `"ASCII-VIA-CLIPRDR-777"`, 21 bytes, arrives as 21 bytes, exact
- Persian, 54 bytes, arrives as **0 bytes**. The X selection changes owner and
  then serves nothing at all
- `"ASCII-AGAIN-888"`, 15 bytes, exact. So the channel is not wedged, it simply
  cannot carry that item

FreeRDP says so itself in the log at exactly those moments:

```
[ERROR][com.winpr.clipboard] - [ClipboardGetData]: No synthesizer for format
CF_RAW [0x00000000] --> text/plain [0x0000c000]
```

`/clipboard:` has only `use-selection`, `direction-to` and `files-to`, so there
is no encoding option to tune. Hence the bridge.

- `desk` runs `-clipboard` and starts `bin/desk-clip`, which is base64 in,
  base64 out over the SSH master, with no codepage anywhere in the path
- leaving the RDP channel on as well is not an option. xrdp-chansrv and the
  bridge both want to own the X CLIPBOARD selection, and chansrv wins often
  enough to hand back the broken copy at random. One owner or none
- `DESK_CLIP=rdp desk` puts the old behaviour back
- text only. Images and files still go through the `/drive:mac` share
- ceiling: `MAX_BYTES` is 2 MB, and anything larger is skipped with a log line
- if `desk-clip` is not found, `desk` now says so on screen instead of starting
  a session with no clipboard and no message

## Shift+Enter

This was the client eating the key, not Linux ignoring it. FreeRDP's SDL client
owns its own shortcuts, and their modifier defaults to Right Shift.

- proof, from `~/.cache/remote-claude-desk/last.log`:
  `<KMOD_RSHIFT>+<SDL_SCANCODE_RETURN> pressed, toggling fullscreen state`
- Right Shift plus M was minimise, Right Shift plus Enter was fullscreen
- fix: `~/.config/freerdp/sdl-freerdp.json` sets `SDL_KeyModMask` to
  `["KMOD_RSHIFT","KMOD_RALT","KMOD_RCTRL"]`, a combination nobody hits by
  accident
- source file: `mac/sdl-freerdp.json`. Delete the installed copy to put the old
  behaviour back
