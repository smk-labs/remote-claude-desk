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
- bounded retry loops everywhere: 12 layout tries, 15 display tries, a 20 second
  agent start timeout, 10 consecutive bridge failures before it gives up loudly
- `desk_ssh` sets `ConnectTimeout=10` on every remote call, so no call hangs
- the preflight in `bin/desk` and the reaper on the server both handle the
  orphaned session (trap 7)
- `bin/desk-doctor` checks all of it in one pass and names the cause

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
