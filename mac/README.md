# The Mac side

Four small changes to your Mac so a Linux desktop feels like a Mac window.

```sh
./mac/install.sh      # set it up
./mac/uninstall.sh    # take it back out
```

## What install.sh does

It puts three commands on your PATH and drops two config files where macOS apps look for them.

- Links `bin/desk`, `bin/desk-doctor` and `bin/desk-tunnel` into `~/bin`, with absolute symlinks into this repo.
- Refuses to overwrite a real file of the same name in `~/bin`, and says so instead.
- Writes `~/.config/freerdp/sdl-freerdp.json`, backing up any existing file as `sdl-freerdp.json.bak-<stamp>`.
- Copies `mac/karabiner-rules.json` to `~/.config/karabiner/assets/complex_modifications/remote-claude-desk.json`.
- Reports what is missing (`sdl-freerdp` from `brew install freerdp`) and installs nothing on its own.
- Safe to re-run. It skips work that is already done.

## 1. The desk commands

Three commands you type in a terminal, one to connect and two to fix things.

- `desk` connects: SSH master, port forward, keyboard layout, then FreeRDP.
- `desk-doctor` checks both ends and tells you which one is broken.
- `desk-tunnel` forwards the RDP port on its own, for when you want the tunnel without the window.
- All three read `config.sh`, from `~/.config/remote-claude-desk/config.sh` first, then the repo.

## 2. The FreeRDP shortcut override

One line of config so Shift+Enter reaches the app you are typing in.

- FreeRDP's SDL client owns its own shortcuts, and the default modifier is Right Shift.
- So Right Shift plus Enter toggled fullscreen, and Right Shift plus M minimised the window.
- `SDL_KeyModMask` moves those onto Right Shift plus Right Alt plus Right Ctrl, which nobody presses by accident.
- File: `~/.config/freerdp/sdl-freerdp.json`.

## 3. The Karabiner rules

Mac muscle memory, translated to Windows and Linux key combinations, but only inside the remote desktop window.

| You press | You get | Rule |
| --- | --- | --- |
| Cmd + Left / Right | Start / end of the line | 9 Essential Mac Navigation Keys |
| Cmd + Up / Down | Start / end of the document | 9 Essential Mac Navigation Keys |
| Option + Left / Right | Jump one word (Ctrl + arrow) | 9 Essential Mac Navigation Keys |
| Option + Delete | Delete the word before the cursor (Ctrl + Backspace) | 9 Essential Mac Navigation Keys |
| Cmd + Delete | Delete to the start of the line | 9 Essential Mac Navigation Keys |
| Cmd + Shift + Left / Right | Select to the start / end of the line | 9 Essential Mac Navigation Keys |
| Cmd + Q | Close the window (Alt + F4) | RDP: Cmd+Q and Cmd+W |
| Cmd + W | Close the tab (Ctrl + W) | RDP: Cmd+Q and Cmd+W |
| Fn (globe) | Switch keyboard language in the session | Fn to Shift+Option and F18 |

Install copies the file. You enable the rules yourself:

1. Open Karabiner-Elements, go to Complex Modifications, click Add rule.
2. Enable the three rules under "Mac keys inside a remote Linux desktop".

The script never edits your `karabiner.json`. That file holds every device, profile and rule you own, so a bad write there costs you your whole keyboard setup. The assets folder is Karabiner's own import door, and Karabiner rereads it on its own.

### The caveat, and why the Fn key has two routes

Karabiner cannot always tell that the window in front is FreeRDP, so the Fn key is wired twice.

- `sdl-freerdp` is a bare binary with no app bundle, so `NSRunningApplication.bundleIdentifier` is nil for it.
- Karabiner's usual `bundle_identifiers` condition therefore never matches, and the rules fall back to `file_paths`, which matches the binary path instead.
- `file_paths` is the weaker test, so the rule can fail to fire.
- Route one: the rule fires and Fn becomes Shift+Option, the Windows language switch.
- Route two: the rule does not fire, Fn arrives as F18, and the server binds X keycodes 191 to 202 (F13 to F24) to `ISO_Next_Group`.
- Two independent paths on purpose. Either one switches the language.

## 4. The menu bar app (optional)

A small icon in the menu bar that connects without a terminal.

- Build it with `bar/build`, which compiles `bar/desk-bar.swift` into `/Applications/Desk.app`.
- Machines are listed one per line in `~/.config/desk-bar/machines`, as `name = command`.
- `install.sh` does not build it. It is optional and takes a Swift compiler.

## Undoing it

One script takes back exactly what the install script added.

- `./mac/uninstall.sh` removes the `~/bin` symlinks, but only symlinks pointing into this repo.
- It restores `sdl-freerdp.json` from the newest backup, or removes the file if there was no backup.
- It removes the Karabiner asset file.
- Two things it deliberately leaves alone, and prints at the end: your Keychain password (`security delete-generic-password -s remote-claude-desk`) and any rules you already enabled in Karabiner's window (turn them off there).
