# Isolation, and why it needs two things

A desktop app on the server must not read or write your central `~/.claude` or
`~/.codex`. A separate app profile is not enough on its own, and this is the
part people get wrong.

One launcher template, `server/app-isolated`, covers every app, because all of
them are Electron and take the same Chromium flags. Install one with
`server/install.sh --app NAME`, where NAME is `claude`, `chatgpt` or `zcode`.
See [../server/README.md](../server/README.md).

## Both halves are required

The Desktop profile holds the app's own state. Claude Code sessions read
plugins, skills and MCP servers from somewhere else entirely.

- `--user-data-dir="$ROOT/profile"` covers the app: windows, cache, login state
- `CLAUDE_CONFIG_DIR="$ROOT/claude-config"` covers Claude Code. It ignores the
  app profile completely and defaults to `~/.claude`. The name is load-bearing:
  live installs already hold hundreds of MB there, and renaming the directory
  would point them at an empty one with no error
- `CODEX_HOME="$ROOT/codex-home"` does the same for Codex. The ChatGPT Linux
  app is the Codex build, so it ships the same leak under a different name
- both agent homes are set for every app, not just the one that owns them,
  because either app can start an agent
- all are set in the launcher, so a session started from inside the app
  inherits them
- `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` are redirected under the same root
- `XDG_DATA_HOME` is deliberately **not** redirected. The secret store is the
  session keyring, which lives with the daemon owning `org.freedesktop.secrets`.
  Moving the data dir does not move the keyring, it only breaks the lookup

## The proof

Set one variable and the same command gives a different answer. That is the
whole test.

- `claude plugin list` in the work directory shows the full central set by
  default, and **zero** with `CLAUDE_CONFIG_DIR` set to the isolated path
- the central `~/.claude.json` was 62397 bytes with an unchanged mtime before
  and after, so nothing wrote to it
- the isolated `.claude.json` is the one being written

## How it is enforced, not just intended

Four guards, so the isolation does not depend on anyone remembering it.

- the launcher refuses to run as anyone but the account it was installed for
- it refuses any X display below `DESK_DISPLAY_MIN`, and any display whose
  socket is not owned by you. On a shared box other tenants run `Xvfb -ac`, so
  a stray `DISPLAY` opens your app on a stranger's screen
- the isolated root is mode `700`. Two other accounts were tried and both got
  `Permission denied`
- the packaged menu entry is overridden with `NoDisplay=true`, so only the
  isolated entry can be clicked
- the working directory is `$ROOT/work` and it is empty, so no `CLAUDE.md` is
  picked up by directory walking

## Egress, on a box that needs a proxy

A box whose egress is blocked needs the app pointed at a local proxy, and one
flag is not enough to do it.

- the launcher reads `$ROOT/env`, mode `600`, never in git. Set `PROXY_URL`
  there, for example `socks5://127.0.0.1:2080`
- it is a file rather than a stamped flag so the proxy can change without a
  reinstall, and so a box with clean egress simply has no file
- `--proxy-server` covers only Chromium's network stack. The same block also
  exports `HTTPS_PROXY`, `HTTP_PROXY` and `ALL_PROXY`, because these apps ship
  native agent binaries whose own HTTP clients would otherwise egress direct
- a box with clean egress must **not** have the file. A proxy that is configured
  but down fails closed, which looks exactly like the app being broken
- the file is read once, at launch. Writing it while the app is running changes
  nothing, and relaunching does not help either: Electron's single-instance lock
  hands the second launch to the instance already running, which silently keeps
  the old flags. Check `--proxy-server` on the actual process, not the file, and
  quit the app fully before expecting a change to take

## What this does not cover

File isolation is not privilege isolation, and on one of the two boxes that gap
is real.

- the app runs as the login account, so it inherits whatever that account can do
- on `ousmousa` the account is in `sudo` with `NOPASSWD` and in `docker`. Either
  one is root, so the app is effectively root there and no launcher flag changes
  that
- on `claude-box` the account has neither, so the app cannot reach root
- closing the gap means taking those two memberships away, which is a decision
  about that account, not about this launcher

## The one leak

Testing the isolation is what dirtied the thing it was protecting.

- the negative control ran `claude plugin list` against the central directory,
  which left 8 `.in_use` marker files in `~/.claude/plugins/cache`
- stale, harmless, and not yet removed
- worth knowing before you run the same negative control
