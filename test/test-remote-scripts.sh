# The remote scripts are real code and must be checked like it.
#
# This file is the whole reason remote/ exists. 227 lines used to live inside
# heredocs and a Python r-string, where a hard syntax error passed both
# `bash -n` and `shellcheck -x` without a word. Now every one of them is parsed
# on every test run.
# shellcheck shell=bash

for f in "$ROOT"/remote/*.sh; do
  name="remote/$(basename "$f")"
  if bash -n "$f" 2>/dev/null; then ok "$name parses"; else bad "$name has a syntax error"; fi
done

for f in "$ROOT"/remote/*.py; do
  name="remote/$(basename "$f")"
  if python3 -m py_compile "$f" 2>/dev/null; then ok "$name parses"
  else bad "$name has a syntax error"; fi
done
rm -rf "$ROOT/remote/__pycache__"

if command -v shellcheck >/dev/null 2>&1; then
  for f in "$ROOT"/remote/*.sh; do
    name="remote/$(basename "$f")"
    n="$(shellcheck -S warning "$f" 2>&1 | grep -cE '\(warning\)|\(error\)')"
    is "$n" "0" "$name is shellcheck clean"
  done
else
  ok "shellcheck not installed, skipped (syntax was still checked)"
fi

# The scripts read their input from the environment, never from values pasted
# into them, which is what desk_remote_run relies on to stay injection-safe.
contains "$(cat "$ROOT/remote/find-display.sh")" '$MIN' "find-display.sh reads MIN from the environment"
contains "$(cat "$ROOT/remote/apply-layout.sh")" '$LAYOUTS' "apply-layout.sh reads LAYOUTS from the environment"
contains "$(cat "$ROOT/remote/check.sh")" '$MIN' "check.sh reads MIN from the environment"

# No payload may be re-embedded as a string literal. This is the regression
# guard for the finding that started the whole refactor.
for f in "$ROOT"/bin/* "$ROOT"/lib/*.sh; do
  name="$(basename "$f")"
  if grep -q "<<'REMOTE" "$f" 2>/dev/null || grep -q "^REMOTE_AGENT = r'''" "$f" 2>/dev/null; then
    bad "$name has re-embedded a remote payload as a string literal"
  fi
done
ok "no remote payload is embedded as a string literal"
