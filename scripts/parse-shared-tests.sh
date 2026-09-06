#!/bin/bash
set -uo pipefail
#
# parse-shared-tests.sh — Step 11.2b `**Shared tests (split-role):**` parser
# (#1287).
#
# This was an inline awk one-liner inside a ```bash fence in
# skills/evaluate-issue-pr/SKILL.md. The harness rewrites `$0`/`$1`... when it
# loads a skill body, so a fence carrying an awk field reference can never
# survive a load intact (cycle-1 observed: `awk '{sub(/\r$/,"",1281)}'`). The
# program moved VERBATIM into this script, which the harness never rewrites —
# `$0`/`$1` are safe here.
#
# Contract: stdin = plan body; stdout = one sanctioned shared-test path per
# line, in source order; exit 0 ALWAYS (fail-open — callers run under
# `set -euo pipefail`, and a parser that aborts would wedge a PR evaluation).
#
# Shared-test exemption (#1089, Direction 3). Two supported forms:
#   header-inline: `**Shared tests (split-role):** tests/test-foo.sh` (#1107)
#   following-bullet: `**Shared tests (split-role):**\n- tests/test-foo.sh`
# Reads until the next `**...:**` header. These are the EXACT repo-relative
# test file paths the plan sanctioned for green-role modification.
#
# Parse-contract hardening (#1263): (1) an unconditional leading CRLF strip so
# a trailing \r never survives into a parsed path (a surviving \r would
# silently defeat the gate's exact-string match, reintroducing a false block
# by a different vector); (2) the armed bullet region closes on ANY non-bullet
# line — an ATX heading, prose, or another bold "**...:**" header — so
# unrelated content later in the same comment is never swept in as a bogus
# shared-test path. A BLANK line closes the region only once the section has
# "started" (`started` = the header line carried an inline value, or a bullet
# was already consumed). That keeps the common markdown shape
# `**Shared tests (split-role):**\n\n- tests/foo.sh` — a blank line between a
# header-ONLY line and its own bullet list — parsing to the declared path
# instead of an empty carve-out (an empty carve-out would fail closed into a
# false `locked-test-modified` block), while still bounding a header-INLINE
# section at the first blank line.
#
# `None` / `n/a` (case- and trailing-period-insensitive) yield an EMPTY list,
# never the phantom path "None" (#1178).

awk '{sub(/\r$/,"",$0)} /^\*\*Shared tests \(split-role\):\*\*/{found=1; rest=substr($0, index($0,":**")+3); gsub(/^[ `]+|`[ ]*$/,"",rest); sub(/[ \t]+[—-][ \t].*$/,"",rest); sub(/[ \t]+#.*$/,"",rest); gsub(/[ `]+$/,"",rest); sen=tolower(rest); sub(/\.$/,"",sen); started=(rest!=""); if(rest!="" && sen!="none" && sen!="n/a") print rest; next} found && /^[[:space:]]*$/{if(started) found=0; next} found && !/^[- ]/{found=0} found && /^[- ]/{started=1; gsub(/^[-  `]+|`[ ]*$/,"",$0); sub(/[ \t]+[—-][ \t].*$/,"",$0); sub(/[ \t]+#.*$/,"",$0); gsub(/[ `]+$/,"",$0); sen=tolower($0); sub(/\.$/,"",sen); if($0!="" && sen!="none" && sen!="n/a") print $0}' || true

exit 0
