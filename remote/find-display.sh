#!/usr/bin/env bash
# Print the X display this user's xrdp session is on, or exit 1.
#
# Run on the server by desk_remote_run. Reads MIN from the environment.
#
# Two independent guards, because a shared box has other tenants who run Xvfb
# with -ac and therefore have X access control off: the display number must be
# at or above MIN, and its socket must be owned by us. A display that fails
# either test is not ours to touch.
me="$(id -un)"

# Candidates: the display number on the command line of every xrdp X server
# this user owns. xrdp's Xorg is told ":N ... -config xrdp/xorg.conf", and the
# other tenants run Xvfb, so that config path is what separates ours from
# theirs.
candidates=""
for p in $(pgrep -u "$me" -x Xorg 2>/dev/null); do
  cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" || continue
  case "$cmd" in *xrdp/xorg.conf*) ;; *) continue ;; esac
  for tok in $cmd; do
    case "$tok" in
      :[0-9]*) candidates="$candidates ${tok#:}"; break ;;
    esac
  done
done

# Fallback: any X socket we own. Covers a session whose Xorg is named
# differently, and costs nothing when the loop above already found it.
if [ -z "$candidates" ]; then
  for s in /tmp/.X11-unix/X*; do
    [ -S "$s" ] || continue
    [ "$(stat -c %U "$s" 2>/dev/null)" = "$me" ] || continue
    candidates="$candidates ${s##*/X}"
  done
fi

for n in $(printf '%s\n' $candidates | sort -n -u); do
  case "$n" in ''|*[!0-9]*) continue ;; esac
  [ "$n" -ge "$MIN" ] || continue
  [ "$(stat -c %U "/tmp/.X11-unix/X$n" 2>/dev/null)" = "$me" ] || continue
  printf ':%s\n' "$n"
  exit 0
done
exit 1
