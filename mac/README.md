# The Mac side

Two small changes to your Mac so a Linux desktop feels like a Mac window.

```sh
./mac/install.sh      # set it up
./mac/uninstall.sh    # take it back out
```

The Mac used to run an RDP client of its own. It no longer does: you connect
with Microsoft's Windows App, which brings its own credentials, keyboard
handling and clipboard. What is left here is two commands and one keyboard file.

## What install.sh does

It puts two commands on your PATH and drops the Karabiner rules where Karabiner
looks for them.

- Links `bin/desk-doctor` and `bin/desk-tunnel` into `~/bin`, with absolute
  symlinks into this repo.
- Refuses to overwrite a real file of the same name in `~/bin`, and says so
  instead.
- Copies `mac/karabiner-rules.json` to
  `~/.config/karabiner/assets/complex_modifications/remote-claude-desk.json`.
- Reports what is missing, and installs nothing on its own.
- Safe to re-run. It skips work that is already done.

It does not write any client config, because the client is not ours.

## 1. The desk commands

Two commands you type in a terminal, one to connect and one to find out why you
cannot.

- `desk-tunnel` opens the SSH master, heals an orphaned session, forwards the
  RDP port to `localhost`, and pushes your keyboard layout into the live X
  session. Then it exits: it holds nothing open, the master does.
- `desk-tunnel --install` writes a LaunchAgent, named after this machine, that
  runs the same thing at login and every five minutes. `--uninstall` removes it.
- `desk-doctor` checks both ends and tells you which one is broken.
- Both read `config.sh`, from `~/.config/remote-claude-desk/config.sh` first,
  then the repo. `DESK_CONFIG` names a different file, which is how one Mac
  drives two boxes.

## 2. The Karabiner rules

Mac muscle memory, translated to Windows and Linux key combinations, but only
inside the remote desktop window.

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

The script never edits your `karabiner.json`. That file holds every device,
profile and rule you own, so a bad write there costs you your whole keyboard
setup. The assets folder is Karabiner's own import door, and Karabiner rereads
it on its own.

### Which window the rules apply to

Every rule is scoped to the RDP client and nothing else, by bundle identifier:
`com.microsoft.rdc.macos`, `com.microsoft.rdc.mac` and
`com.microsoft.WindowsApp`. Outside those windows your Mac keyboard is
untouched.

That scoping used to be the weak part. The old client was a bare binary with no
app bundle, so `NSRunningApplication.bundleIdentifier` was nil for it and the
rules had to fall back to matching a file path. Windows App is an ordinary
bundled app, so the strong test works and the `file_paths` fallback is gone.

### Why the Fn key still has two routes

Fn is wired twice, and either route switches the language.

- Route one: the Karabiner rule fires and Fn becomes Shift+Option, the Windows
  language switch.
- Route two: the rule does not fire, Fn arrives as F18, and the server binds X
  keycodes 191 to 202 (F13 to F24) to `ISO_Next_Group`. That happens in
  `remote/apply-layout.sh`, on every connect.

The second route was added because the first could not be verified against a
bundle-less binary. It costs one loop on the server and it stays: two
independent paths to a key you press every few minutes is cheap insurance.

## Undoing it

One script takes back exactly what the install script added.

- `./mac/uninstall.sh` removes the `~/bin` symlinks, but only symlinks pointing
  into this repo.
- It removes the Karabiner asset file.
- It leaves alone any rules you already enabled in Karabiner's window. Removing
  the file does not switch off a rule Karabiner has already copied into your own
  config, so turn those off there.
- It does not touch the LaunchAgent. That is `desk-tunnel --uninstall`, which
  knows the label for this machine.
