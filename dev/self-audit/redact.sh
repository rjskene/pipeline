#!/usr/bin/env bash
# redact.sh — sourced helper. Exposes `redact` which reads stdin and writes
# a redacted stream to stdout per the audit redaction discipline.
#
# Discipline (load-bearing):
#   1. Hard-deny (drop whole line):
#        - token-shaped strings: [A-Za-z0-9]{32,}
#        - keywords (case-insensitive): password, token, secret,
#          api[_-]?key, bearer, Authorization
#        - URLs with ?key= / ?token= / ?auth=
#   2. Length cap: 200 chars per line. Longer lines get truncated to 200
#      chars + the suffix `...[truncated; original N chars]`.
#   3. Triple-backtick blocks: contents stripped; surrounding prose kept.
#      The triple-backticks themselves are dropped too.
#
# Pass-through (allowed): plain prose, conventional-commit messages,
# issue/PR numbers, file paths, GitHub usernames.

redact() {
  awk '
    BEGIN {
      in_block = 0
      hex_pat  = "[A-Za-z0-9]{32,}"
      kw_pat   = "password|token|secret|api[_-]?key|bearer|authorization"
      url_pat  = "\\?(key|token|auth)="
    }
    {
      line = $0

      # 1. Triple-backtick code blocks: toggle, drop the fence and the body.
      if (line ~ /^[[:space:]]*```/) {
        in_block = (in_block == 0) ? 1 : 0
        next
      }
      if (in_block == 1) { next }

      # 2. Hard-deny: token-shaped substring.
      if (line ~ hex_pat) { next }

      # 3. Hard-deny: URL with ?key= / ?token= / ?auth=
      if (line ~ url_pat) { next }

      # 4. Hard-deny: keyword (case-insensitive). lowercase a copy for match.
      lc = tolower(line)
      if (lc ~ kw_pat) { next }

      # 5. Length cap.
      n = length(line)
      if (n > 200) {
        line = substr(line, 1, 200) "...[truncated; original " n " chars]"
      }

      print line
    }
  '
}

# Export the function name so callers that `set -e` and re-source still see it.
export -f redact 2>/dev/null || true
