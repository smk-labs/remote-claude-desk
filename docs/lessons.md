# How this was measured, and where it went wrong

Every claim in these docs has a measurement behind it. This page is the
measurements, the diagnoses that were wrong, and the parts that are still only
reasoned about rather than seen.

It is here because the wrong diagnoses cost more time than the bugs did. Each
one passed a test first.

## The instruments

Three tools, each picked because the obvious one lies.

- **A raw X11 keycode injector.** About 120 lines of Python speaking the X
  protocol straight over the unix socket, with no dependencies, because the
  server has no `xinput`, no `python3-xlib` and no X headers to build against.
  It sends XTEST FakeInput with a real keycode and syncs on every event, so a
  malformed request cannot fail silently
- **NSPasteboard, read through `osascript -l JavaScript`,** as the clipboard
  referee. It reports code points with no locale anywhere in the path
- **sha256 and hexdump on both ends** for every clipboard claim, never the
  rendered text

## Trap 1: xdotool cannot test a keyboard layout

`xdotool key q` looks like it presses the `q` key. It does not, and that made
the first layout test meaningless.

- it looks up a keycode for the keysym you asked for, and when none exists it
  temporarily remaps a scratch keycode to that keysym and presses that
- so it prints `q` whether or not a second layout is loaded
- the first layout test passed for exactly this reason and proved nothing
- with raw keycodes the answer is real: keycode 24 gives `q`, then Option+Shift,
  then keycode 24 gives `ض` and 38 gives `ش`, then Option+Shift and 24 gives `q`
  again
- the same method proved the F18 route: `ض`, F18, `q`, F18, `ض`

## Trap 2: a pbcopy round trip passes even when both ends mangle

A test that passes for the wrong reason is worse than no test. This one produced
a completely wrong diagnosis, with a hexdump that appeared to prove it.

- `pbcopy` and `pbpaste` take their encoding from the caller's locale
- Python exports `LC_CTYPE=C.UTF-8` to its children, a glibc name macOS does not
  know, so both tools fall back to MacRoman
- a `pbcopy | pbpaste` round trip still matches byte for byte, because both ends
  mangle identically
- FreeRDP was blamed for MacRoman corruption on that evidence
- NSPasteboard settled it: the bare `pbcopy` had written 35 wrong code points,
  and with `LC_ALL=en_US.UTF-8` it wrote the correct 23
- the real behaviour, once measured properly, is different in kind. Non-ASCII is
  dropped to zero bytes, not corrupted
- `bin/desk-clip` now pins `LC_ALL` on every pasteboard call (`PB_ENV`) rather
  than inheriting it

## Trap 3: the first bridge design fed itself

The first bridge kept a history of every value it had carried and skipped
anything already in it. That stopped the obvious bounce and broke two real
cases.

- copying the same text twice did nothing the second time
- re-copying on the Mac something you had pasted out of the session did nothing
- and when a hop changed the bytes, the echo looked like fresh input. It ran
  away 35 to 69 to 137 to 1998 bytes and kept going, which froze a paste inside
  the session
- the fix is per-direction change detection, not a history. A value arriving
  from the remote is recorded as the Mac's current value at the same moment it
  is written there, so the Mac poll sees no change and cannot send it back
- echo suppression on the agent side is one shot, cleared the first time the
  poll sees it, plus an 800 ms quiet window after each write, so a read landing
  before `xclip` owns the selection cannot report the old value as news
- `MAX_BYTES` is 2 MB. The loop is fixed, but a ceiling turns any future version
  of that bug into a skipped item instead of a hang

## Trap 4: pkill matching its own shell

`ssh host 'pkill -f deskclip-agent'` returned 255 and left processes alive. It
had killed the thing running it.

- `pkill -f` matches the whole command line, so the pattern also matched the ssh
  shell running the pkill, halfway through the cleanup
- the same mistake twice, in two shapes: `kill -9 -$PGID` and `pkill -f` both
  matched the shell that ran them
- fixed with a bracketed pattern, `[d]eskclip-agent`, which cannot match itself,
  and with `set -m` plus killing by pid where a pattern was not needed
- verified: the command now returns 0 and both processes are gone
- now enforced by `desk_remote_pkill` in `lib/common.sh`, which brackets the
  first character for every caller, so no caller can forget it

The bracket alone is not the whole rule, which is the part that catches people
twice. It stops the PATTERN matching itself, not the COMMAND LINE containing the
literal string somewhere else.

- hit again while packaging this repo, with
  `ssh host 'rm -f /tmp/deskclip-agent.py; pkill -f "[d]eskclip-agent"'`
- the bracketed pattern was correct, but the `rm` argument on the same line put
  the literal `deskclip-agent` into the remote shell's own command line, so
  `pkill` matched the shell and killed it before the rest of the line ran
- exit status 255, the first command's output printed, and nothing after it
- the rule is therefore: a remote kill gets a command line of its own, with
  nothing else on it. `desk_remote_pkill` sends only the `pkill`, which is why
  the shipped code was never affected

## Trap 5: the bridge that was never started

Reported as "the clipboard is stuck again". Nothing was stuck. The bridge was
not running on either side, and the RDP channel is off by design, so text had no
path at all.

- cause: `HERE` came from `dirname "${BASH_SOURCE[0]}"`, and `BASH_SOURCE` holds
  the path the script was **invoked by**, not the target
- `desk` is meant to be run as `~/bin/desk`, a symlink into the repo, so `HERE`
  was `~/bin` and the helper next to it did not exist there
- the `-x` test was the whole condition, so a missing bridge was
  indistinguishable from a healthy start: no error, no log line, a working
  desktop that simply never pasted
- fix, two parts: resolve the symlink chain before taking `dirname`, and print a
  warning when the bridge is still not found
- the real defect was the silent guard on the one component that carries
  non-ASCII text. The path bug only tripped it
- verified after the fix, both directions: Mac to remote, 35 bytes exact, and
  remote to Mac, byte identical

## Trap 6: a hardcoded display number

The display was assumed to be the first one in the range. It is not, often
enough to matter, and everything downstream then fails without a word.

- when a session fails to start on the first display, xrdp hands out the next
  one instead
- the layout push then targets a display that is not there, and the clipboard
  bridge owns a selection nobody reads. Both fail silently, which is the worst
  way for them to fail
- the display is discovered now, by `desk_remote_display` in `lib/common.sh`
- it matches on `xrdp/xorg.conf` in the command line, which is what separates
  our X server from the `Xvfb` the other tenants run
- two guards on the answer: at or above `DESK_DISPLAY_MIN`, and the socket must
  be owned by us
- `desk` waits for it, bounded at 15 tries 2 seconds apart, and says so on
  screen when 30 seconds pass with nothing found

## Trap 7: restarting sesman under a live session

One restart of a background service stranded a desktop session for two days.
Disconnect first, every time.

- `xrdp-sesman` keeps its session list in memory, so a session running at the
  moment of the restart becomes untracked forever
- every later connect then makes a **new** session, which dies at once because
  XFCE cannot start twice for one user, and takes the client with it
- the tell in `xrdp-sesman.log`: a fresh session starting, then
  `Window manager exited quickly (0 secs)`, then ending
- the symptom at the client is `ERRINFO_LOGOFF_BY_USER`, which is not a logoff
- `Policy=UBI` means a session is reused only when user, colour depth and client
  IP all match. Depths 32, 24 and 16 were all tried and all failed, so the depth
  was not the reason and that session was simply unreachable
- it recurs on its own: Ubuntu's unattended upgrades restart sesman. A session
  from Aug 26 outlived a sesman that started Aug 28, on a box last rebooted in
  June
- fixed in two places: a reaper as `ExecStartPre` on sesman, and a preflight in
  `desk` that kills any xrdp Xorg older than sesman

## Trap 8: code inside a string is code nothing checks

Both checkers were clean, and had been for months. They were reading past a
fifth of the code without saying so.

- 227 of the 1273 lines ran on the server, and every one of them lived inside a
  string: heredocs in three commands and a Python r-string in a fourth. Five
  call sites, five different transport shapes
- a heredoc is data, so no parser looks inside it. A deliberate hard syntax
  error was put in one of them, and `bash -n` and `shellcheck -x` both returned
  zero findings
- the same line in an ordinary file failed at once. That is the whole result:
  the checks were not weak, they were never pointed at the code
- the quoting made it worse. Inside two levels of quotes, `$HOME`, a loop
  variable and the closing `$` of a grep pattern each needed a backslash to
  survive, so the text on screen was not the text that ran
- those payloads are files now: `remote/find-display.sh`,
  `remote/heal-orphans.sh`, `remote/apply-layout.sh`, `remote/check.sh` and
  `remote/clip-agent.py`. One function, `desk_remote_run`, ships and runs all
  five
- values reach them as environment assignments in front of the interpreter, not
  pasted into the text, so a quote or a dollar sign in a value cannot change
  what runs
- going back now costs a red test. `test/test-remote-scripts.sh` parses every
  file in `remote/`, runs shellcheck over the shell ones where it is installed,
  and fails if any command re-embeds a payload as a string literal

## Trap 9: matching somebody else's packaging by a name you guessed

The installer hid `/usr/share/applications/claude-desktop.desktop`. The package
ships `com.anthropic.Claude.desktop`. So the step printed "no packaged
claude-desktop.desktop found, nothing to hide", exited zero, and hid nothing.

The failure is not that it did nothing. It is that "the file is not there" and
"the file is called something else" are the same branch when the match is on a
guessed filename, so the installer reported a clean skip for a job it had not
done. The menu then held two Claude entries, the isolated one and one click that
starts the app against the central `~/.claude`, with nothing on screen saying
which was which. Isolation that is one click from being bypassed, next to a
message saying everything is fine.

Match on what a thing DOES, not what it is called. Every entry whose `Exec` line
invokes the `claude-desktop` binary is now shadowed, so the package renaming its
file again changes nothing here. Anchor the pattern at the start of the `Exec`
value and require the binary name to end at a space or end of line, or
`claude-desktop-isolated` matches the prefix and the installer hides the launcher
it just wrote.

And the shadow is a written stub, not a copy of the packaged file with
`NoDisplay=true` appended. A copy brings the packaged `Actions=` across, and each
desktop action is another `Exec` starting the non-isolated binary; docks offer
those from a right-click and some launchers surface them from search even when
the entry itself is NoDisplay. The stub also names itself
"Claude (do not use - not isolated)", because `NoDisplay` is a request to the
menu rather than a guarantee, and anything that does show it should show it
labelled.

## Trap 10: hand-copying a working box instead of running its installer

Setting up a second machine, the units under `~/.config/systemd/user/` were read
off the working box and written by hand. They were correct, and the box still
came up missing things, because the units were never the whole of what the
installer does: `relay-linux install-service` also writes the applications-menu
entry, removes the competing autostart file, and refreshes the desktop database.
Copy the output and you get the output. Run the tool and you get everything the
tool knows.

The visible symptom was "the relay is not in the applications menu", diagnosed
first as "the relay has no menu entry by design". It has one. The reference box
had it all along, in `~/.local/share/applications/claude-relay.desktop`, and one
`ls` of that directory would have said so before any of the reasoning did.

Two smaller versions of the same mistake on the same box:

- `install -d -m 700 -o moe -g moe ~/.config/systemd/user` applies the ownership
  to the last component only, so `~/.config` stayed root-owned. The user could
  not create `~/.config/xfce4`, `xfconfd` exited 1 on every D-Bus activation, and
  the desktop came up as "Unable to load a failsafe session" with a Quit button
  and nothing else. Nothing in that message mentions permissions.
- The packages were installed with `--no-install-recommends`, which left out
  `imagemagick`. The tray's `icons.sh` calls `convert`, printed
  `convert: command not found`, and **exited zero**, so the icon directory stayed
  empty and the menu entry pointed at a PNG that was never drawn.

The rule both of these land on: when a working reference exists, read it, and
diff against it. Not "does the new box work", but "what does the old box have
that this one does not".

## Three more mistakes worth not repeating

Each of these looked like a different bug than it was.

- **I attached to another user's screen.** The box has nine users. `Xvfb :99`
  failed silently because another account had owned `:99` for months, so the app
  landed on their session. Every tenant runs `Xvfb -ac`, so X access control is
  off for all of them. The launcher now refuses any display below the floor or
  not owned by you
- **I turned the codec off for the wrong reason.** The vertical stripes were 24
  bit colour. Blaming RemoteFX dropped updates onto the legacy bitmap path and
  caused a different crash an hour later
- **I claimed a test passed that never ran the code.** Eight connections
  "survived" with zero crashes. The harness only held the socket open. It never
  exercised the failing path

## What this taught the code

Each lesson above is now a function or a check, so it is enforced rather than
remembered.

- `desk_remote_pkill` in `lib/common.sh` brackets every remote kill pattern, so
  no caller can kill its own shell (trap 4)
- `desk_remote_display` in `lib/common.sh` discovers the display and refuses one
  below the floor or not owned by you (trap 6, and the shared-box mistake)
- `desk_resolve` and an inline `realpath` before every `dirname` stop the
  symlink bug, and a missing bridge now prints a warning (trap 5)
- `PB_ENV` in `bin/desk-clip` pins the locale on every pasteboard call (trap 2)
- `MAX_BYTES` in `bin/desk-clip` is a 2 MB ceiling that turns a runaway loop
  into a skipped item (trap 3)
- `desk_remote_run` in `lib/common.sh` is the only way code reaches the server.
  Every payload is a file in `remote/`, parsed and linted like the rest, and its
  input is passed as environment assignments rather than pasted in (trap 8)
- `desk_retry` in `lib/common.sh` is the one bounded loop, and it replaced six
  hand-written ones that were each correct and none of them enforced. Callers
  say how many tries, how long apart, and how many passes in a row count:
  12 tries for the layout and three in a row, 15 tries for the display.
  `bin/desk-clip` keeps its own loops, because it is Python, and its ceilings
  are a 20 second agent start and 10 consecutive failures before it says so
- `desk_ssh` sets `ConnectTimeout=10` on every remote call, so no call hangs
- `desk_build_args` in `lib/freerdp-args.sh` is pure, so the flags that carry
  the most hard-won knowledge here are finally checkable. `test/run` asserts
  them, including the rule that broke the screen: never 24-bit colour
- the preflight in `bin/desk` and the reaper on the server both handle the
  orphaned session (trap 7)
- `bin/desk-doctor` checks all of it in one pass and names the cause. A remedy
  is a `fix` line now, on both sides of the connection: `remote/check.sh` sends
  one `STATUS<tab>TEXT` line per result, so a hint on the server prints the same
  way as a hint on the Mac instead of hiding in brackets inside a message
- `desk_load_config` refuses a `config.sh` that group or others can write to.
  The file is sourced, so everything in it runs, which on a shared box makes a
  writable config someone else's shell

## What is not verified

Stated plainly, because the rest of this page is not.

- **No real Cmd or Fn keypress was ever observed.** The shell had no
  Accessibility permission, so it could not post CGEvents, and there was no
  other way to synthesise a key on the Mac side. The scancodes are confirmed
  against FreeRDP's own table and the flag is confirmed in the running process,
  but the result was never seen
- **Karabiner matching a bundle-less binary** through `file_paths` is reasoned
  from how `NSWorkspace` reports the process, not measured. That is exactly why
  the F18 route exists as an independent second path
- **A live paste from a dictation tool** into the session was never run, for the
  same reason. The unit test covers the decision, not the keystroke

Granting Accessibility to the terminal would close all three.

### Open question: a lone modifier in a `to` array

A review raised this and it was never tested. Recording it as a question, not a
fact.

- file: `mac/karabiner-rules.json`, rule
  `9 Essential Mac Navigation Keys to Windows`
- the Cmd+Left manipulator has
  `"to": [{"key_code":"left_control"},{"key_code":"home"}]`, and Cmd+Right has
  the same shape with `end`
- if Karabiner holds a lone modifier in a `to` array until the end of the
  sequence, those send Ctrl+Home and Ctrl+End, which is document start and
  document end, rather than plain Home and End, which is line start and line end
- Karabiner's published docs do not state the rule either way
- the Cmd+Shift+Left and Cmd+Shift+Right manipulators have the same shape, so
  they would be affected the same way
- what would settle it: press Cmd+Left in a multi-line field inside the session
  and see whether the caret goes to the start of the line or the start of the
  document
