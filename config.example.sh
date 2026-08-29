# remote-claude-desk: the one file you edit.
#
# Copy it and fill in the first two values:
#
#     cp config.example.sh config.sh
#
# config.sh is gitignored. If you would rather keep the clone pristine, put the
# same file at ~/.config/remote-claude-desk/config.sh instead; that path wins.
#
# Everything here is a shell variable, so it is also overridable per run:
#
#     DESK_SIZE=2560x1600 desk

# ─── required ────────────────────────────────────────────────────────────────

# The SSH host. Use an alias from ~/.ssh/config, not an IP: the alias is what
# carries your key, your user and the ControlMaster settings. Minimum entry:
#
#     Host mybox
#       HostName 203.0.113.10
#       User me
#       ControlMaster auto
#       ControlPath ~/.ssh/ctrl-mybox
#       ControlPersist yes
#       ServerAliveInterval 15
#
DESK_HOST="${DESK_HOST:-mybox}"

# The Linux user that owns the desktop session. This is the account you type at
# the RDP login, and the one the listener is locked to on the server.
DESK_USER="${DESK_USER:-me}"

# ─── the listener ────────────────────────────────────────────────────────────
# Where xrdp listens ON THE SERVER. The defaults are deliberately not
# 0.0.0.0:3389: a dedicated loopback address cannot collide with anything else
# on a shared box, and a non-standard port keeps it out of the way. If you
# change them, pass the same values to the server installer:
#   server/install.sh --rdp-addr <addr> --rdp-port <port>
DESK_RDP_ADDR="${DESK_RDP_ADDR:-127.0.0.77}"
DESK_RDP_PORT="${DESK_RDP_PORT:-33890}"

# The local end of the SSH tunnel. Change it only if something else has the port.
DESK_LOCAL_PORT="${DESK_LOCAL_PORT:-33890}"

# ─── display ─────────────────────────────────────────────────────────────────
# The lowest X display number this setup will touch. On a shared box other
# tenants own the low numbers, and several of them run Xvfb with -ac, which
# turns access control off entirely. Attaching to one of those means your app
# opens on a stranger's screen. This floor is what stops that, so raise it
# rather than lower it, and pass the same number to the server installer:
#   server/install.sh --display-min <n>
DESK_DISPLAY_MIN="${DESK_DISPLAY_MIN:-150}"

# Pin the display instead of discovering it. Leave empty. `desk` asks the server
# which display your session is actually on, which is right even when xrdp
# hands out :151 after a failed :150. Set it only to debug a specific session.
DESK_DISPLAY="${DESK_DISPLAY:-}"

# ─── keyboard ────────────────────────────────────────────────────────────────
# Layouts pushed into the live X session on every connect, and the key that
# switches between them. xrdp overwrites the keymap after xfce4-settings has
# had its say, so this has to be re-applied per connection; it is never written
# to any server config.
#
# One layout is fine: DESK_LAYOUTS="us" and the toggle is simply unused.
DESK_LAYOUTS="${DESK_LAYOUTS:-us,ir}"
DESK_LAYOUT_TOGGLE="${DESK_LAYOUT_TOGGLE:-grp:alt_shift_toggle}"

# ─── local paths ─────────────────────────────────────────────────────────────
# Folder shared into the session as the "mac" drive. Files go through here.
DESK_SHARE="${DESK_SHARE:-$HOME/RemoteShare}"

# macOS Keychain item holding the Linux password for the RDP login. Created by
# `desk setup`; read at connect time and fed to FreeRDP on stdin, so it never
# appears in `ps` or in a file.
DESK_KEYCHAIN_SERVICE="${DESK_KEYCHAIN_SERVICE:-remote-claude-desk}"

# ─── bringing the SSH master up ──────────────────────────────────────────────
# Optional. Leave it empty and `desk` runs a plain `ssh -fNM`, which is right
# whenever your key alone gets you in.
#
# Set it to a command if your server needs something else first: a TOTP prompt,
# a hardware key, a VPN, a jump host. It is run with no arguments and must leave
# a live master on DESK_SSH_SOCKET. This exists because the alternative is
# forking the script, and the login dance is the one part of this that is
# different at every site.
#
#     DESK_CONNECT_CMD="$HOME/bin/ssh-totp -fNM -S \$DESK_SSH_SOCKET \$DESK_HOST"
#
DESK_CONNECT_CMD="${DESK_CONNECT_CMD:-}"

# The control socket. Must match ControlPath in ~/.ssh/config for that host.
DESK_SSH_SOCKET="${DESK_SSH_SOCKET:-$HOME/.ssh/ctrl-$DESK_HOST}"
