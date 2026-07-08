# shellcheck shell=bash
# Shared CRLF-jq seam for issue #1158.
#
# Git-for-Windows `jq` (msvcrt text-mode) terminates every output line with
# \r\n. Command substitution and `read` strip the trailing \n but leave the
# \r, poisoning any value that meets a CR-free comparand (lookup keys,
# grep -Fxq / grep -qx exact matches, end-anchored regexes, [ x = y ] tests).
#
# This lib reproduces that faithfully on an LF-only CI host: a fake `jq`
# placed earlier on PATH wraps the real jq and appends a CR to each output
# line, propagating jq's exit status (so `jq -e` boolean checks still work).
#
#   make_crlf_jq_bin <bindir>
#     - writes <bindir>/jq (a +x wrapper around the real jq)
#     - runs a NON-VACUITY od -c guard: `printf '[1]' | jq -r '.[]'` must show
#       a CR through the fake bin, else the seam is a silent no-op and every
#       downstream assertion would vacuously "pass" — returns non-zero then.
#
# Usage (scope PATH to the single helper invocation, not the whole test):
#   source "$SCRIPT_DIR/_lib/crlf-jq-seam.sh"
#   make_crlf_jq_bin "$TMP/bin" || { echo "seam setup failed"; exit 1; }
#   PATH="$TMP/bin:$PATH" bash "$HELPER" ...

make_crlf_jq_bin() {
  local bindir="$1"
  local real_jq
  real_jq="$(command -v jq)"
  if [ -z "$real_jq" ]; then
    echo "crlf-jq-seam: real jq not found on PATH (cannot build seam)" >&2
    return 1
  fi
  mkdir -p "$bindir"
  cat > "$bindir/jq" <<EOF
#!/bin/bash
# CRLF-emitting jq wrapper (msvcrt text-mode simulation) — issue #1158.
# Portable awk CR injection (NOT GNU-specific sed); propagate jq's status.
set -o pipefail
"$real_jq" "\$@" | awk '{printf "%s\r\n",\$0}'
exit \${PIPESTATUS[0]}
EOF
  chmod +x "$bindir/jq"

  # Non-vacuity guard — the seam MUST inject a CR. od -c renders a CR byte as
  # the two-character token backslash-r; grep for it as a fixed string.
  if ! printf '[1]' | PATH="$bindir:$PATH" jq -r '.[]' | od -c | grep -qF '\r'; then
    echo "crlf-jq-seam: NON-VACUITY GUARD FAILED — fake jq did not emit CR" >&2
    return 1
  fi
  return 0
}
