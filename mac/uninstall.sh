#!/usr/bin/env bash
# Undo mac/install.sh, and nothing else.
#
# It removes only what install.sh created: three symlinks, one FreeRDP config,
# one Karabiner asset file. It never touches your karabiner.json, your Keychain,
# your config.sh, or anything else in your home directory.
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
BIN_LINKS="desk desk-doctor desk-setup desk-tunnel"
FREERDP_FILE="$HOME/.config/freerdp/sdl-freerdp.json"
KARABINER_FILE="$HOME/.config/karabiner/assets/complex_modifications/remote-claude-desk.json"

usage() {
  cat <<'USAGE'
uninstall.sh - undo mac/install.sh.

    ./mac/uninstall.sh          remove what install.sh added
    ./mac/uninstall.sh --help   this text

It removes the ~/bin symlinks, restores or removes the FreeRDP config, and
removes the Karabiner asset file. It leaves your Keychain item and any rules
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
# 2. the FreeRDP shortcut override
# ---------------------------------------------------------------------------

desk_say "2. FreeRDP shortcuts"

# Newest backup wins, and the names sort by time because the stamp is
# year first. A glob avoids parsing ls output, which breaks on odd filenames.
newest=""
for candidate in "$FREERDP_FILE".bak-*; do
  if [ -f "$candidate" ]; then
    newest="$candidate"
  fi
done

if [ -n "$newest" ]; then
  cp -p "$newest" "$FREERDP_FILE"
  rm -f "$newest"
  desk_say "   restore $FREERDP_FILE from $newest"
elif [ -f "$FREERDP_FILE" ]; then
  # No backup means the file did not exist before install.sh wrote it. If it
  # still matches what we wrote, it is ours to remove. If it does not, someone
  # edited it since, and their edit outranks this script.
  if cmp -s "$FREERDP_FILE" "$HERE/sdl-freerdp.json"; then
    rm -f "$FREERDP_FILE"
    desk_say "   removed $FREERDP_FILE (there was no file here before)"
    desk_say "           Shift+Enter goes back to being eaten by the client."
  else
    desk_warn "   KEPT    $FREERDP_FILE has been edited since install. Left alone."
  fi
else
  desk_say "   gone    nothing to remove"
fi
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

desk_say "Done. Two things were left alone on purpose:"
desk_say ""
desk_say "  * Your Keychain password. Deleting a password is not something a"
desk_say "    script should do behind your back. Remove it yourself with:"
desk_say ""
desk_say "        security delete-generic-password -s remote-claude-desk"
desk_say ""
desk_say "  * Any rules you already enabled in Karabiner. Removing the file above"
desk_say "    does not switch off a rule Karabiner has already copied into your"
desk_say "    own config. Open Karabiner-Elements, go to Complex Modifications,"
desk_say "    and remove the \"RDP:\", \"9 Essential\" and \"Fn to\" rules."
desk_say ""
desk_say "The repo itself is untouched. Delete the folder when you are done with it."
