# Isolation, and why it needs two things

Claude Desktop on the server must not read or write your central `~/.claude`. A
separate Desktop profile is not enough on its own, and this is the part people
get wrong.

The launcher that does all of this is `server/claude-desktop-isolated`, installed
by `server/install.sh --claude`. See [../server/README.md](../server/README.md).

## Both halves are required

The Desktop profile holds the app's own state. Claude Code sessions read
plugins, skills and MCP servers from somewhere else entirely.

- `--user-data-dir="$ROOT/profile"` covers the app: windows, cache, login state
- `CLAUDE_CONFIG_DIR="$ROOT/claude-config"` covers Code. It ignores the Desktop
  profile completely and defaults to `~/.claude`
- both are set in the launcher, so a Code session started from inside the app
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

## The one leak

Testing the isolation is what dirtied the thing it was protecting.

- the negative control ran `claude plugin list` against the central directory,
  which left 8 `.in_use` marker files in `~/.claude/plugins/cache`
- stale, harmless, and not yet removed
- worth knowing before you run the same negative control
