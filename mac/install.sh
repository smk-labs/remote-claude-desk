#!/usr/bin/env bash
# Install the macOS side of remote-claude-desk.
#
# Four small things, none of them clever:
#   1. check what is missing
#   2. put desk-doctor and desk-tunnel on your PATH
#   3. build bin/desk-pbio, which is how the clipboard bridge reads images
#   4. offer the Karabiner rules to Karabiner, without editing its config
#
# Safe to run again. Nothing here installs software and nothing here writes
# outside your home directory.
set -euo pipefail

# ---------------------------------------------------------------------------
# where am I
# ---------------------------------------------------------------------------

# Resolve through symlinks before taking the parent directory. A plain
# `dirname "$0"` gives the directory the script was INVOKED from, which is the
# wrong answer the moment anyone links this file somewhere convenient, and the
# wrong answer is silent: it links a set of files that are not this repo's.
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/.." && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
if [ -f "$ROOT/lib/common.sh" ]; then
  . "$ROOT/lib/common.sh"
else
  printf '%s\n' "Cannot find $ROOT/lib/common.sh. Run this from inside the repo." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# settings
# ---------------------------------------------------------------------------

BIN_DIR="$HOME/bin"
# The list lives in lib/common.sh, sourced above, so this cannot drift from it.
BIN_LINKS="$DESK_COMMANDS"
KARABINER_DIR="$HOME/.config/karabiner/assets/complex_modifications"
KARABINER_FILE="$KARABINER_DIR/remote-claude-desk.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

MISSING=0

usage() {
  cat <<'USAGE'
install.sh - set up the macOS side of remote-claude-desk.

    ./mac/install.sh          install or re-install
    ./mac/install.sh --help   this text

What it does:
  * links desk-doctor and desk-tunnel into ~/bin
  * copies the Karabiner rules into Karabiner's own import folder
  * reports missing dependencies, and installs nothing itself

Undo it with ./mac/uninstall.sh
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) desk_die "Unknown option: $1 (try --help)" ;;
esac

desk_say "remote-claude-desk: installing the macOS side"
desk_say "repo: $ROOT"
desk_say ""

# ---------------------------------------------------------------------------
# 1. dependencies
# ---------------------------------------------------------------------------

desk_say "1. Dependencies"

# nc opens no connection here, it only proves the tunnel answers. It ships with
# macOS, so a miss means something is wrong with the system, not with this
# install.
if command -v nc >/dev/null 2>&1; then
  desk_say "   ok      nc"
else
  desk_say "   MISSING nc"
  MISSING=$((MISSING + 1))
fi

if command -v karabiner_cli >/dev/null 2>&1 || [ -d "/Applications/Karabiner-Elements.app" ]; then
  desk_say "   ok      Karabiner-Elements"
else
  desk_say "   NOTE    Karabiner-Elements is not installed. Without it, the Mac"
  desk_say "           keys stay Mac keys inside the session."
  desk_say "           brew install --cask karabiner-elements"
fi
desk_say ""

# ---------------------------------------------------------------------------
# 2. commands on PATH
# ---------------------------------------------------------------------------

desk_say "2. Commands in $BIN_DIR"

mkdir -p "$BIN_DIR"

for name in $BIN_LINKS; do
  target="$ROOT/bin/$name"
  link="$BIN_DIR/$name"

  if [ ! -f "$target" ]; then
    desk_warn "   skip    $name is not in $ROOT/bin"
    continue
  fi
  [ -x "$target" ] || chmod +x "$target"

  # A real file with our name is somebody else's work. Overwriting it is the
  # one mistake in an installer nobody can undo, so it stops and reports.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    desk_warn "   REFUSE  $link exists and is a real file, not a link."
    desk_warn "           Move it yourself, then run this again."
    MISSING=$((MISSING + 1))
    continue
  fi

  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    desk_say "   ok      $name is already linked"
    continue
  fi

  ln -sfn "$target" "$link"
  desk_say "   linked  $link -> $target"
done

# ~/bin exists now, but an installer that leaves you with a command you cannot
# type has done nothing. Say the exact line rather than "add it to your PATH".
case ":$PATH:" in
  *":$BIN_DIR:"*) desk_say "   ok      $BIN_DIR is on your PATH" ;;
  *)
    case "${SHELL:-}" in
      */zsh)  profile="$HOME/.zshrc" ;;
      */bash) profile="$HOME/.bash_profile" ;;
      *)      profile="your shell profile" ;;
    esac
    desk_say "   NOTE    $BIN_DIR is not on your PATH. Add this line to $profile:"
    desk_say ""
    desk_say "               export PATH=\"\$HOME/bin:\$PATH\""
    desk_say ""
    desk_say "           Then open a new terminal."
    ;;
esac
desk_say ""

# ---------------------------------------------------------------------------
desk_say "3. The pasteboard helper"

# desk-clip reads the Mac pasteboard through this rather than through pbpaste,
# which speaks text only, so an image would be invisible to the bridge. pbpaste
# also takes its encoding from the environment, which is how a Persian copy came
# back as MacRoman (docs/lessons.md, trap 2).
PBIO_SRC="$ROOT/mac/pbio.swift"
PBIO_OUT="$ROOT/bin/desk-pbio"
if ! command -v swiftc >/dev/null 2>&1; then
  desk_say "   NOTE    swiftc is not here, so images will not cross. Install the"
  desk_say "           Xcode command line tools:  xcode-select --install"
elif [ -x "$PBIO_OUT" ] && [ "$PBIO_OUT" -nt "$PBIO_SRC" ]; then
  desk_say "   ok      $PBIO_OUT is already built"
elif swiftc -O -o "$PBIO_OUT" "$PBIO_SRC" 2>/dev/null; then
  desk_say "   built   $PBIO_OUT"
else
  desk_say "   MISSING $PBIO_OUT would not build, so images will not cross"
fi
desk_say ""

# ---------------------------------------------------------------------------
# 4. the Karabiner rules
# ---------------------------------------------------------------------------

desk_say "4. Karabiner rules"

# The rules are copied into Karabiner's own import folder and never merged into
# karabiner.json by hand. That file holds every device, profile and rule the
# user owns, so a bad write there costs them their whole keyboard setup, and
# Karabiner rewrites the file itself whenever it feels like it. The assets
# folder is the supported door: Karabiner rereads it on its own and shows what
# it finds, so the user stays the one who decides.
mkdir -p "$KARABINER_DIR"
cp "$HERE/karabiner-rules.json" "$KARABINER_FILE"
desk_say "   copied  $KARABINER_FILE"
desk_say ""
desk_say "   Two steps left, and only you can do them:"
desk_say "     1. Open Karabiner-Elements, go to Complex Modifications, click Add rule."
desk_say "     2. Enable the three rules under \"Mac keys inside a remote Linux desktop\"."
desk_say ""

# ---------------------------------------------------------------------------
# what next
# ---------------------------------------------------------------------------

if [ "$MISSING" -gt 0 ]; then
  desk_say "Done, with $MISSING thing(s) to fix above."
else
  desk_say "Done."
fi

desk_say ""
desk_say "What next:"
desk_say "    cp $ROOT/config.example.sh $ROOT/config.sh"
desk_say "    \$EDITOR $ROOT/config.sh     # set DESK_HOST and DESK_USER"
desk_say "    desk-doctor                  # checks both ends"
desk_say "    desk-tunnel                  # open the tunnel, then connect with your RDP client"
desk_say ""
desk_say "Undo everything: $HERE/uninstall.sh"
