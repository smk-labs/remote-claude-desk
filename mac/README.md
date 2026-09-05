# The Mac side

A few small changes to your Mac so a Linux desktop feels like a Mac window.

```sh
./mac/install.sh      # set it up
./mac/uninstall.sh    # take it back out
```

The Mac used to run an RDP client of its own. It no longer does: you connect
with Microsoft's Windows App, which brings its own credentials and keyboard
handling. What is left here is two commands, one clipboard helper and one
keyboard file.

## What install.sh does

Four numbered steps, and it prints them in this order as it goes.

1. Checks what is missing and says so. It installs nothing itself.
2. Links `bin/desk-doctor` and `bin/desk-tunnel` into `~/bin`, with absolute
   symlinks into this repo. It refuses to overwrite a real file of the same name
   there, and says so instead.
3. Builds `bin/desk-pbio` from `mac/pbio.swift` with `swiftc`.
4. Copies `mac/karabiner-rules.json` to
   `~/.config/karabiner/assets/complex_modifications/remote-claude-desk.json`.

Safe to re-run. It skips work that is already done. It does not write any client
config, because the client is not ours.

## 1. Dependencies

Nothing is installed for you, so this step only names what is absent.

- `nc` ships with macOS. A miss means something is wrong with the system.
- Karabiner-Elements is optional. Without it the Mac keys stay Mac keys inside
  the session.
- `swiftc` comes with the Xcode command line tools,
  `xcode-select --install`. Without it step 3 is skipped and images cannot cross
  on the clipboard.

## 2. The desk commands

Two commands you type in a terminal, one to connect and one to find out why you
cannot.

- `desk-tunnel` opens the SSH master, heals an orphaned session, forwards the
  RDP port to `localhost`, pushes your keyboard layout into the live X session,
  and starts the clipboard bridge. Then it exits: it holds nothing open, the
  master does.
- `desk-tunnel --install` writes a LaunchAgent, named after this machine, that
  runs the same thing at login and every five minutes. `--uninstall` removes it.
- `desk-doctor` checks both ends and tells you which one is broken.
- Both read `config.sh`, from `~/.config/remote-claude-desk/config.sh` first,
  then the repo. `DESK_CONFIG` names a different file, which is how one Mac
  drives two boxes.

## 3. The pasteboard helper

Windows App's own clipboard has to stay off, because an image reaching the Mac
pasteboard while the client is redirecting towards the remote side deadlocks the
app. `bin/desk-clip` carries both directions over the SSH master instead, and
this step gives it eyes.

- `bin/desk-pbio` is a small Swift binary, built here from `mac/pbio.swift` and
  left beside the commands. It reads the pasteboard through `NSPasteboard`.
- That matters because `pbpaste` speaks text only, so an image would be
  invisible to the bridge, and because `pbpaste` takes its encoding from
  whatever environment it inherits, which once turned a Persian copy into
  MacRoman.
- Neither `desk-clip` nor `desk-pbio` goes on your PATH. `desk-tunnel` finds
  them next to itself, so neither is meant to be typed.
- Turning the client's clipboard off is a step only you can do. Both routes are
  in [../docs/keyboard-and-clipboard.md](../docs/keyboard-and-clipboard.md).

## 4. The Karabiner rules

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

One script takes back what the install script put outside this repo.

- `./mac/uninstall.sh` removes the `~/bin` symlinks, but only symlinks pointing
  into this repo.
- It removes the Karabiner asset file.
- It leaves `bin/desk-pbio` where it was built, because that is inside the repo
  and goes when the repo does.
- It leaves alone any rules you already enabled in Karabiner's window. Removing
  the file does not switch off a rule Karabiner has already copied into your own
  config, so turn those off there.
- It does not touch the LaunchAgent. That is `desk-tunnel --uninstall`, which
  knows the label for this machine.
