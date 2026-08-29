# Server side

Four small changes to the Linux box. Each one fixes something that broke
without it.

## What changes, and why

Out of the box, xrdp cannot read its own TLS key, hands out displays other
people own, answers every account on the machine, and leaves dead X servers
behind.

- **User `xrdp` joins group `ssl-cert`.** Ubuntu leaves it outside the group
  owning `/etc/xrdp/key.pem`, so every TLS handshake fails.
- **`port=tcp://127.0.0.77:33890`, `X11DisplayOffset=150`, `Policy=UBI`.** A
  private loopback address cannot collide on a shared box. The display floor
  keeps you off the low displays, where other tenants run `Xvfb -ac` with X
  access control switched off.
- **`xrdp-lock-user.service`.** One iptables OWNER rule. Without it, any
  account here can reach your RDP login prompt over loopback.
- **`xrdp-reap-orphans`, an `ExecStartPre=` drop-in on sesman.** A drop-in, not
  an edit of the packaged unit, which an upgrade would undo. It kills X servers
  that outlived sesman.

Opt-in: `--keyring` unlocks the login keyring at RDP login, so Claude Desktop
stays signed in. `--claude` installs the isolated launcher.

## Install

Run it on the server, from this directory.

```sh
sudo ./install.sh --user alice --keyring --claude
```

It prints the plan, asks once, then acts. Steps check first, so re-running is
safe. Edited config files get a `.rcd-bak-<timestamp>` copy, and
`sudo ./uninstall.sh` puts them back.

| File | Role |
| --- | --- |
| `install.sh` | idempotent installer, prints its plan and waits for a yes |
| `uninstall.sh` | reverses it from the timestamped backups |
| `xrdp-lock-user.service` | template, one iptables OWNER rule |
| `xrdp-reap-orphans` | kills X servers that outlived sesman |
| `claude-desktop-isolated` | template, Claude Desktop with its own config and profile |

Templates carry `@DESK_USER@` style placeholders. `install.sh` fills them in,
so the files in git stay generic.

## Never restart sesman under a live session

Disconnect first. Every time.

- sesman keeps its session list in memory, so a session that outlives a restart
  is untracked forever.
- Every later connect then makes a NEW session, which dies at once because XFCE
  cannot start twice for one user.
- Both scripts detect a live session with `pgrep -u <user> -f 'xrdp/xorg.conf'`
  and refuse. Restarting `xrdp` alone is safe: it drops the connection, not the
  session.

## What is not changed

Nothing outside xrdp, and nothing is deleted.

- Packaged units, sshd, the firewall beyond that one rule, other users' files.
- `~/.claude` and `~/.claude.json`. The launcher points `CLAUDE_CONFIG_DIR`
  somewhere else instead.
- `XDG_DATA_HOME`, on purpose. The keyring lives with the daemon owning
  `org.freedesktop.secrets`, so moving the data dir breaks the lookup rather
  than moving the keyring.
- Uninstall keeps the isolated root, so profile, work and logs survive.
