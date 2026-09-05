# Removal plan: dropping the FreeRDP client

Analysis only. Nothing in this plan has been applied. Every claim below is
backed by a grep or a run, and where the evidence runs out it says so.

Baseline, measured today: `./test/run` → **101 passed, 0 failed**
(test-args.sh 25, test-common.sh 52, test-remote-scripts.sh 24).

Removing everything recommended here deletes about **1,510 lines** across 9
files and leaves the suite at roughly **49 checks**.

---

## 1. Verdict per file

### Dead once FreeRDP is gone

| File | LoC | What actually references it |
|---|---|---|
| `bin/desk` | 501 | `mac/install.sh` (via `DESK_COMMANDS`), `bin/desk-doctor:104,127`, `test/test-common.sh` (14 checks), `bar/desk-bar.swift`, README, CONTEXT, all four docs |
| `lib/freerdp-args.sh` | 97 | sourced only by `bin/desk:31` and `test/test-args.sh:6` |
| `mac/sdl-freerdp.json` | 3 | `mac/install.sh:198,206`, `mac/uninstall.sh:101`, `bin/desk-doctor:201` |
| `test/test-args.sh` | 72 | `test/run:35` glob. Every one of its 25 checks is a FreeRDP flag |
| `bin/desk-setup` | 41 | `lib/common.sh:55` (`DESK_COMMANDS`), `bin/desk-doctor:191`, `bin/desk:419,424`, README:84,105 |
| `bin/desk-clip` | 336 | `bin/desk:352-359`, `bin/desk-tunnel:148-157`, `bin/desk-doctor:183-185`, `test/test-common.sh:125,130,276,278,280,314` |
| `bin/desk-pbio` | built | not tracked (`.gitignore:16`); built by `mac/install.sh:177-187`; read by `bin/desk-clip:55` |
| `mac/pbio.swift` | 73 | `mac/install.sh:176`, `bin/desk-clip:55`, `test/test-common.sh:211-214` |
| `remote/clip-agent.py` | 77 | `bin/desk-clip:106` only. Nothing else on the server runs it |
| `bar/` (`desk-bar.swift` 266 + `build` 44) | 310 | `bin/desk-doctor:164` (a `fix` line), `mac/install.sh:250`, `mac/README.md:77-78`, `test/test-common.sh:46,91,112` |

**The Keychain is genuinely dead.** `security find-generic-password` appears in
exactly three files: `bin/desk-setup`, `bin/desk:345-346` and
`bin/desk-doctor:187`. Windows App keeps its own credentials, so nothing reads
the item once `bin/desk` is gone.

**The clipboard bridge is genuinely dead**, with one condition. Windows App
carries Unicode text itself, and images are handled server-side by
`remote/clip-png.sh`. But see §4: `remote/clip-png.sh` has **no caller anywhere
in this repo**, so verify it is actually running on the server before deleting
the bridge.

### Partly needed: `mac/karabiner-rules.json` — KEEP, edit only

This file has **no FreeRDP bundle identifier at all**. Every one of the 14
conditions names the same three apps:

```
"^com\\.microsoft\\.rdc\\.macos$", "^com\\.microsoft\\.rdc\\.mac$", "^com\\.microsoft\\.WindowsApp$"
```

FreeRDP enters only through a second key on the same condition object:

```json
"type": "frontmost_application_if",
"file_paths": [ "sdl-freerdp" ]
```

`file_paths` appears at lines **16, 52, 92, 127, 162, 197, 232, 267, 302, 337,
375, 414, 458, 490** — 14 blocks, four lines each. Karabiner ORs the two keys
inside one condition, so deleting the `file_paths` key leaves every rule
matching Windows App exactly as it does today.

All three rules survive: `RDP: Cmd+Q to Alt+F4 and Cmd+W to Ctrl+W` (line 5),
`9 Essential Mac Navigation Keys to Windows` (line 81), `Fn to Shift+Option
(Win) and F18 (Mac)` (line 447).

Confirmed: there is **no Option+V rule** in this file. `grep -n '"key_code":
"v"' mac/karabiner-rules.json` returns nothing. The repo file is already
missing what was deleted live today, so nothing to reconcile.

Two edits beyond the `file_paths` blocks:
- line 2, the title, still says `(FreeRDP)`.
- line 450 vs 481: rule 2's second manipulator is a
  `frontmost_application_unless`. Dropping `file_paths` there means Fn→F18 now
  also fires when a FreeRDP window is frontmost. Harmless once FreeRDP is gone.

### Keep as-is

`bin/desk-tunnel` (minus the bridge block), `lib/common.sh` (minus two lines),
`remote/*`, `server/*`, `test/test-remote-scripts.sh` (minus one check),
`docs/lessons.md` (history, not instructions).

---

## 2. What breaks, by file

### `lib/common.sh`
- **line 55** `DESK_COMMANDS="desk desk-doctor desk-setup desk-tunnel"` → must
  become `"desk-doctor desk-tunnel"`. It is the single source for `mac/install.sh:40`,
  `mac/uninstall.sh:23` and `bin/desk-doctor:169`.
- **line 120** `: "${DESK_KEYCHAIN_SERVICE:=remote-claude-desk}"` → dead.
- Lines 30, 358 mention the bridge in comments (harmless, but now misleading).

### `bin/desk-doctor` — nine blocks to prune
| Lines | Check | Action |
|---|---|---|
| 52-57 | `sdl-freerdp` on PATH | delete |
| 59-94 | reads `DiagnosticReports/sdl-freerdp*.hang` | delete |
| 96-119 | two-desk lock collision (reads `desk-*.pid`) | delete |
| 121-134 | `pgrep -f "[s]dl-freerdp /v:..."` nice level | delete |
| 136-138 | `xfreerdp` needs XQuartz warning | delete |
| 140-142 | `python3 present (the clipboard bridge needs it)` | delete or reword |
| 159-167 | login-shell PATH check | **keep**, but line 164's fix names `bar/build` |
| 183-185 | `desk-clip is next to desk` | delete |
| 187-192 | Keychain item | delete |
| 198-207 | `~/.config/freerdp/sdl-freerdp.json` shortcut override | delete |
| 209-218 | **line 210 greps live `karabiner.json` for `sdl-freerdp`** | **repoint to `WindowsApp`** |

Line 210 is the trap: it reads the user's *live* `~/.config/karabiner/karabiner.json`,
not the repo file. That live file currently holds 14 `sdl-freerdp` and 14
`WindowsApp` entries (verified on this machine), so the check passes today and
would keep passing after the repo edit until the user re-imports. Repoint it to
`WindowsApp` or it will report green for the wrong reason forever.

### `bin/desk-tunnel`
- **122-159** the whole bridge block, plus **line 164** `Clipboard: ${bridge_note}`.
- **13-16** the header comment about what a native client does not get: now wrong
  in the other direction.
- **Must gain one line.** See §4, orphan healing.

### `mac/install.sh`
- 41-42 `FREERDP_DIR` / `FREERDP_FILE`; 57-58 usage text; 82-88 sdl-freerdp
  dependency check; 93-100 `security` dependency check (only desk-setup used it);
  170-187 the pbio build; 189-209 section 4, the FreeRDP shortcut file; 248
  `desk # connect`; 250 `bar/build`.
- After this it does two things: symlinks and Karabiner. Renumber the sections.

### `mac/uninstall.sh`
- 4-6 header, 24 `FREERDP_FILE`, 34-36 usage, **78-110 all of section 2**,
  131-137 the Keychain paragraph.
- **Silent breakage:** it removes only links named in `DESK_COMMANDS`. Once that
  list shrinks, `~/bin/desk` and `~/bin/desk-setup` are left behind forever and
  no script will ever clean them.

### `server/install.sh`, `server/uninstall.sh`, `remote/*`
No FreeRDP, clipboard-bridge or Keychain references. Verified by grep. Two
wording fixes only:
- `remote/check.sh:99` — `need xclip ... "the clipboard bridge needs it"`. xclip
  is still needed, by `remote/clip-png.sh`. Reword, do not delete.
- `remote/check.sh:102` — `need python3 ... "the clipboard agent cannot run"`
  at severity `bad`. After `remote/clip-agent.py` goes, the only python3 user on
  the server is `remote/scroll-probe.py`, a manual diagnostic. Downgrade to `warn`.

### `~/bin` symlinks (live, this machine)
```
desk         -> .../remote-claude-desk/bin/desk          DANGLES
desk-doctor  -> .../bin/desk-doctor                      fine
desk-setup   -> .../bin/desk-setup                       DANGLES
desk-tunnel  -> .../bin/desk-tunnel                      fine
```
`~/Projects/CLAUDE.md` names "the four `~/bin` symlinks into remote-claude-desk"
as a place that holds hardcoded paths. It becomes two. Worth a line in
`docs/ledger.md`.

### LaunchAgents (live)
`com.smk-labs.desk-tunnel.claude-box.plist` and
`com.smk-labs.desk-tunnel.ousmousa.plist` both run `$ROOT/bin/desk-tunnel`.
**Neither is affected.** Nothing in this plan touches them.

### `/Applications/Desk.app` (live, installed)
Every menu row runs `desk`. After removal it gets `command not found` into
`~/.cache/desk-bar.log`, which nobody opens — this repo's own documented
failure shape. Delete the app, do not leave it broken.

### Docs that become wrong
- `README.md`: 84, 98, 105, 132-139, 148, 160, 167-168, 182, 192.
  Lines 45 and 124-139 already say "five commands" and "the five scripts" —
  `remote/` has held seven files for a while, so that count is already stale.
- `CONTEXT.md`: 16 (the client *is* sdl-freerdp), 20-22 (the bridge), 24 ("five"),
  46 (lifetime table row), 60-67 (`freerdp-args.sh`), 78.
- `mac/README.md`: sections **2** (30-38) and **4** (73-79) delete outright;
  16-18, 25, 64-67, 86, 88 edit.
- `docs/why-these-settings.md`: **76 lines, and roughly 60 of them are FreeRDP
  flags** (colour depth, `/size`, `/smart-sizing`, `/rfx`, `/f`, `-sound`,
  `/drive`, `/cert:ignore`). Only "One session, never two" (43-54) is server-side
  and survives. Recommend deleting the file and folding those 12 lines into
  `server/README.md`.
- `docs/keyboard-and-clipboard.md`: section "The Command key" (25-41) and
  "Shift+Enter" (130-142) delete; "The clipboard" (95-129) rewrites to one
  paragraph; "Four problems, four homes" (10-24) loses two of four rows;
  "Karabiner" 52-55 must stop claiming `file_paths` is why the rules match.
- `docs/troubleshooting.md`: rows at 25, 31, 34, 38, 39, 40 all describe FreeRDP
  faults. Row 28 stays and becomes the *only* image story — see §4.
- `docs/lessons.md`: **do not prune.** It is a record of what was measured, and
  traps 2, 3, 4, 5, 11, 12, 15 remain true history. At most add one line saying
  the FreeRDP client was abandoned on 2026-09-04 and why. Lines 353-355, 364,
  367 name files that will not exist; that is acceptable in a history document,
  but say so once at the top rather than editing each.

---

## 3. Tests: exactly what goes

### `test/test-args.sh` — delete the whole file (25 checks)
It sources `lib/freerdp-args.sh` at line 6. Every assertion is a client flag.

### `test/test-common.sh` — 26 of 52 checks go

Delete with `bin/desk` / `lib/freerdp-args.sh` (14):
| Line | Check name |
|---|---|
| 227 | desk chooses SDL's renderer rather than letting it default |
| 228 | desk defaults that renderer to opengl, not metal |
| 236 | desk takes a lock named after the machine's own port |
| 238 | desk ends the previous desk, not just its client |
| 242 | desk-doctor reads the hang reports macOS files about the client |
| 253 | cleanup does not release the lock |
| 254 | the lock is released by the exit trap instead |
| 265 | desk checks the priority it was started at |
| 266 | desk-doctor reports the client's priority |
| 276 | each bridge carries the machine it belongs to |
| 278 | --restart ends only this machine's bridge |
| 280 | --restart no longer kills every bridge |
| 290 | desk decides whether the swap waits for the display |
| 291 | desk defaults that wait to off |

**Note the coupling:** `desk_src` is defined at line 226 by `cat "$ROOT/bin/desk"`
and is still read at 276-291. All of these must die in the same commit as
`bin/desk`, including the three desk-clip ones, even if `bin/desk-clip` itself
survives one more commit.

Delete with `bar/` (5): lines **47, 92, 93, 104, 114**
(the ~/bin PATH check, the two pgrep/ps checks, the `ps -Ao command=` probe,
and the default-port agreement between Swift and shell).

Delete with `mac/pbio.swift` (3): lines **212, 213, 214**.

Delete with `bin/desk-clip` (2): lines **314** (`desk-tunnel starts the
clipboard bridge`) and **315** (`desk-tunnel says what the bridge did`).

Delete with `desk-clip`/`desk-pbio` (2): the loop at **130-135**. Note it would
*not* fail — it asserts the helpers are absent from `DESK_COMMANDS`, which stays
true. It just becomes meaningless. Same for the `grep -vE '^(desk-clip|desk-pbio)$'`
filter at **line 125**: simplify it, it will not break.

**Rewrite, do not delete — line 127**, `DESK_COMMANDS lists every command in
bin/ except desk-clip`. This one compares the list against `ls bin/`, so it is
self-adjusting: shrink `DESK_COMMANDS` and delete the files in the same commit
and it stays green. Only the description needs updating.

Survives untouched (26): `desk_retry` (13-31), `desk_remote_pkill` (37-39),
`server/install.sh` desktop-entry checks (57-81), the config-permission and
`DESK_CONFIG` block (154-194), and the desk-tunnel layout / LaunchAgent /
setsid checks (303, 304, 316, 322).

### `test/test-remote-scripts.sh` — 1 of 24 goes
Only the `remote/*.py` parse loop at 14-18 shrinks, when `clip-agent.py` is
deleted. Everything else survives, including the clip-png checks at 84-86.

One caveat, flagged as **uncertain**: lines 47-56 assert the Caps Lock unlatch
in `apply-layout.sh`, and the comment explains it as *FreeRDP mirroring the X
LED state onto the Mac keyboard*. Whether Windows App mirrors LEDs the same way
has not been tested. The guard is safe either way (it only fires when X itself
says the lock is on), so **keep the code and the test**; the comment's
explanation may need re-measuring.

### Add one test
`desk-tunnel heals an orphaned session` — see §4. Without it, the behaviour is
lost silently, which is precisely the failure mode this repo exists to prevent.

---

## 4. Three things that break silently

These are the ones a file-by-file deletion would miss.

**1. `remote/heal-orphans.sh` loses its only caller.**
```
bin/desk:216   desk_remote_run heal-orphans.sh >/dev/null 2>&1 || true
```
That is the sole call site in the repo. Delete `bin/desk` and orphan healing
stops happening, while `remote/check.sh:116` goes on printing *"desk heals this
automatically on the next run"* — a message that is now false. An orphaned
session makes every later connect die at once, which is invisible from the
client side.

Fix: move the line into `bin/desk-tunnel` right after `desk_ensure_master`
(line 100), and add a test assertion. `desk-tunnel` already re-runs every five
minutes via the LaunchAgent, so it is a better home than `desk` ever was.

**2. `remote/clip-png.sh` has no caller anywhere in this repo.**
`grep -rn clip-png` hits only `test/test-remote-scripts.sh:84-86` and
`docs/troubleshooting.md:28`. That doc line says *"run `remote/clip-png.sh` in
the session (it has an autostart entry)"*, but `grep -n "autostart" server/install.sh`
returns **nothing** — the installer creates no such entry. Either it was made
by hand on the live box (I cannot see the server from here, so this is
**unverified**), or the doc is wrong.

This matters now because once the bridge goes, `clip-png.sh` is the *only* path
an image has. Confirm it is running on the server before deleting `bin/desk-clip`,
and make `server/install.sh` write `~/.config/autostart/clip-png.desktop` so a
rebuild does not lose it.

**3. Eleven per-run knobs become dead words.**
`DESK_SIZE`, `DESK_FULL`, `DESK_BPP`, `DESK_CMD`, `DESK_CLIP`, `DESK_SPACES`,
`DESK_GFX`, `DESK_GDI`, `DESK_RENDERER`, `DESK_VSYNC`, `RDP_TUNE`, `DESK_ASK`.
They live in `bin/desk --help` (41-56), `lib/freerdp-args.sh`, `CONTEXT.md:60-61`
and `docs/why-these-settings.md`. All go with the client.

One exception: **`DESK_SIZE` is still read by `bin/desk-doctor:279`** and judged
by `remote/check.sh:215-224` against the server's core count. Keep both. But
nothing sets it now, so the check is really asking *"can this box encode the
framebuffer Windows App negotiates?"*. Reword the comment at `desk-doctor:274-276`
and at `remote/check.sh:215` accordingly, and keep the `1920x1080` default.

---

## 5. Removal order

Five commits. `./test/run` is green after every one. Run it after each.

### Commit 1 — Karabiner first, so the keyboard never stops working
- `mac/karabiner-rules.json`: delete the 14 `file_paths` blocks (lines listed in
  §1); fix the title at line 2.
- `bin/desk-doctor:210`: grep the live config for `WindowsApp`, not `sdl-freerdp`;
  reword 211-214.
- `docs/keyboard-and-clipboard.md:52-55`, `mac/README.md:64-67`.
- Tests: **no change**. Nothing in `test/` reads this file. Still 101.
- Manual step afterwards: re-import in Karabiner-Elements, or the live
  `karabiner.json` keeps its 14 stale `sdl-freerdp` entries. Harmless, but the
  doctor will be checking a file that no longer matches the repo.

### Commit 2 — the client
Delete `bin/desk`, `lib/freerdp-args.sh`, `mac/sdl-freerdp.json`, `test/test-args.sh`.
- `lib/common.sh:55`: drop `desk` from `DESK_COMMANDS`.
- `bin/desk-tunnel`: **add the `heal-orphans.sh` call** after line 100.
- `bin/desk-doctor`: prune blocks 52-57, 59-94, 96-119, 121-134, 136-138, 198-207.
- `mac/install.sh`: 41-42, 57-58, 82-88, 189-209, 248, 250.
- `mac/uninstall.sh`: 4-6, 24, 34-36, 78-110.
- `test/test-common.sh`: delete the 14 checks listed in §3; add the heal-orphans
  assertion.
- `docs/why-these-settings.md`: delete, folding 43-54 into `server/README.md`.
- Docs: README, CONTEXT, `mac/README.md` section 2, `docs/troubleshooting.md`
  rows 25/31/40, `docs/keyboard-and-clipboard.md` sections 25-41 and 130-142.
- Expected: **101 → 63** (25 from test-args, 14 from test-common, +1 new).

Ordering reason: the client must go before the bridge, because `bin/desk` is the
one file that references *both*. Reversing this leaves `bin/desk` calling a
`desk-clip` that is gone — the exact silent no-clipboard failure documented as
trap 5.

### Commit 3 — the clipboard bridge
**Precondition: confirm `remote/clip-png.sh` is actually running on the server.**
Delete `bin/desk-clip`, `mac/pbio.swift`, `remote/clip-agent.py`; remove the
built `bin/desk-pbio` and its `.gitignore:16` line.
- `bin/desk-tunnel`: delete 122-159 and 164; fix the header comment 13-16.
- `bin/desk-doctor`: delete 140-142 and 183-185.
- `mac/install.sh`: delete 170-187 and the `security` check at 93-100 if
  desk-setup is going too; renumber sections.
- `remote/check.sh`: reword 99, downgrade 102 to `warn`.
- `server/install.sh`: add the clip-png autostart entry.
- `test/test-common.sh`: delete 130-135, 211-214, 314, 315; simplify 125-127.
- Docs: `CONTEXT.md:20-22,24,46`, `docs/keyboard-and-clipboard.md:95-129`,
  `docs/troubleshooting.md:34,38,39`.
- Expected: **63 → 57**.

### Commit 4 — the menu bar app
Delete `bar/`.
- `test/test-common.sh`: delete lines 47, 92, 93, 104, 114.
- `bin/desk-doctor:164`: the fix line names `bar/build`. Keep the check
  (159-167) — the login-shell PATH question still applies to the LaunchAgent —
  but rewrite the advice.
- `mac/install.sh:250`, `mac/README.md:73-79`, `README.md:139`.
- Expected: **57 → 52**.

### Commit 5 — desk-setup and the Keychain
Delete `bin/desk-setup`.
- `lib/common.sh`: line 55 (`DESK_COMMANDS`), line 120 (`DESK_KEYCHAIN_SERVICE`).
- `config.example.sh:73-76`.
- `bin/desk-doctor:187-192`.
- `mac/uninstall.sh:131-137`.
- `README.md:84,105,182`.
- Expected: **52, unchanged** — line 127's check is self-adjusting.

### After the last commit: the live machine
Not part of the repo, and nothing in `mac/uninstall.sh` will do it once
`DESK_COMMANDS` shrinks:
```
rm ~/bin/desk ~/bin/desk-setup
rm -rf /Applications/Desk.app
rm -f ~/.config/freerdp/sdl-freerdp.json
security delete-generic-password -s remote-claude-desk
```
Leave `~/.config/desk-bar/machines` alone unless you are sure nothing else reads
it. Add a line for each to `~/Projects/docs/ledger.md`.

---

## 6. Where I am not sure

- **The clip-png autostart entry.** The doc claims it exists; the installer does
  not create it. I cannot see the server from here. Verify before commit 3.
- **Caps Lock LED mirroring.** `remote/apply-layout.sh:40` explains the unlatch
  as a FreeRDP behaviour. Whether Windows App mirrors LEDs the same way is
  untested. Keep the code either way.
- **Karabiner condition semantics.** I am confident `bundle_identifiers` and
  `file_paths` are ORed within one condition object, and the live config's 14
  matching `WindowsApp` entries are consistent with that. It has not been
  re-tested after the edit. Test one key (Cmd+left) before commit 2.
- **`DESK_SHARE` / `/drive:mac`.** File sharing moved from a FreeRDP flag to
  Windows App's own folder redirection. `desk-tunnel:169` already tells the user
  to add the folder in the client, and `desk-doctor:194-196` still checks the
  directory exists. Both look correct, but I did not test a redirected folder.
