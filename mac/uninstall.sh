#!/usr/bin/env bash
# Undo mac/install.sh, and nothing else.
#
# It unlinks the commands from ~/bin and removes one Karabiner asset file. It
# never touches your karabiner.json, your config.sh, or anything else in your
# home directory.
set -euo pipefail

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

BIN_DIR="$HOME/bin"
# The list lives in lib/common.sh, sourced above, so this cannot drift from it.
BIN_LINKS="$DESK_COMMANDS"
KARABINER_FILE="$HOME/.config/karabiner/assets/complex_modifications/remote-claude-desk.json"

usage() {
  cat <<'USAGE'
uninstall.sh - undo mac/install.sh.

    ./mac/uninstall.sh          remove what install.sh added
    ./mac/uninstall.sh --help   this text

removes the Karabiner asset file. It leaves any rules
you enabled in Karabiner's window alone, and tells you how to clear those.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) desk_die "Unknown option: $1 (try --help)" ;;
esac

desk_say "remote-claude-desk: removing the macOS side"
desk_say ""

# ---------------------------------------------------------------------------
# 1. the commands
# ---------------------------------------------------------------------------

desk_say "1. Commands in $BIN_DIR"

for name in $BIN_LINKS; do
  link="$BIN_DIR/$name"

  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    desk_say "   gone    $name was not there"
    continue
  fi

  # Two guards, because "desk" is a short word somebody else may have used
  # first. Delete only a symlink, and only one that points into this repo.
  if [ ! -L "$link" ]; then
    desk_warn "   KEPT    $link is a real file, not our link. Left alone."
    continue
  fi

  dest="$(readlink "$link")"
  case "$dest" in
    "$ROOT"/*) rm -f "$link"; desk_say "   removed $link" ;;
    *) desk_warn "   KEPT    $link points at $dest, outside this repo. Left alone." ;;
  esac
done
desk_say ""

# ---------------------------------------------------------------------------
# 3. the Karabiner asset
# ---------------------------------------------------------------------------

desk_say "3. Karabiner rules file"

if [ -f "$KARABINER_FILE" ]; then
  rm -f "$KARABINER_FILE"
  desk_say "   removed $KARABINER_FILE"
else
  desk_say "   gone    $KARABINER_FILE was not there"
fi
desk_say ""

# ---------------------------------------------------------------------------
# what is left on purpose
# ---------------------------------------------------------------------------

desk_say "Done. Three things were left alone on purpose:"
desk_say ""
desk_say "  * bin/desk-pbio, which install.sh built rather than downloaded. It is"
desk_say "    ignored by git and costs nothing to leave; delete it by hand if you"
desk_say "    want the checkout spotless."
desk_say ""
desk_say "  * The per-machine LaunchAgents, if you installed any. This script"
desk_say "    never made them, so it does not remove them. One command each:"
desk_say ""
desk_say "        DESK_CONFIG=<that machine's config> desk-tunnel --uninstall"
desk_say ""
desk_say "  * Any rules you already enabled in Karabiner. Removing the file above"
desk_say "    does not switch off a rule Karabiner has already copied into your"
desk_say "    own config. Open Karabiner-Elements, go to Complex Modifications,"
desk_say "    and remove the \"RDP:\", \"9 Essential\" and \"Fn to\" rules."
desk_say ""
desk_say "The repo itself is untouched. Delete the folder when you are done with it."
