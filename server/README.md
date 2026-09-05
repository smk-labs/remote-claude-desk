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

## One session, never two

XFCE cannot start twice for one user, so a second session dies instantly and
takes the client down with it.

- `Policy=UBI` in `sesman.ini` reuses the session when user, colour depth and
  client IP all match, which is what makes a reconnect return to your desktop
  instead of starting a new one.
- `X11DisplayOffset=150` keeps our displays clear of other tenants on a shared
  box, several of whom run `Xvfb -ac` with X access control switched off.
- Both are set by `install.sh`. The same floor is `DESK_DISPLAY_MIN` on the Mac
  side, and both the isolated launcher and `desk_remote_display` refuse anything
  below it.
- On xrdp 0.10 the offset needs a ceiling to sit under. `MaxDisplayNumber`
  defaults to 63, so an offset of 150 leaves an empty range and every login
  fails with "No X displays are available". `install.sh` does not write that
  key, so add it to `[Sessions]` yourself after an upgrade. Raise the ceiling,
  never lower the offset.

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

## The two session helpers

Neither is installed by `install.sh`, because both live in the user's own home
rather than in the system. Both are silent when missing, which is exactly why
`remote/check.sh` now asks about them: the clipboard simply stops carrying
images, and the keyboard simply comes up as plain `us`, and nothing says why.

**`clip-png.sh`** converts the clipboard image xrdp hands to X. The channel
offers `image/bmp` and nothing else, while Chromium, Electron and GTK all ask
for `image/png`, so a paste looks like nothing happening at all. Needs `xclip`
and ImageMagick.

```sh
mkdir -p ~/.local/bin ~/.config/autostart
cp remote/clip-png.sh ~/.local/bin/ && chmod +x ~/.local/bin/clip-png.sh
printf '%s\n' '[Desktop Entry]' 'Type=Application' \
  'Name=Clipboard image as PNG (remote desktop)' \
  "Exec=$HOME/.local/bin/clip-png.sh" 'X-GNOME-Autostart-enabled=true' \
  'NoDisplay=true' > ~/.config/autostart/clip-png.desktop
```

**`xrdp-layout`** puts the keyboard layout back. xrdp sets the session keymap
from what the client announces, after xfce4-settings has had its say, so every
session comes up as plain `us` whatever the server is configured with. It has to
run per connection, from two places, because a session is entered two ways:
`/etc/xrdp/reconnectwm.sh` for reconnecting to a session that already exists,
and an autostart entry for one being created. Add `/usr/local/bin/xrdp-layout &`
to `reconnectwm.sh`, which ships empty for exactly this purpose.
