#!/usr/bin/env bash
# shellcheck shell=bash
# Shared SKILL.md BODY helper for pipeline bash tests (issue #1218).
#
# WHY THIS EXISTS
# ---------------
# A prose guard that greps the WHOLE SKILL.md can be satisfied by the YAML
# frontmatter `description:` line alone — the whole body clause it was written
# to pin can be deleted and the guard still reports green. Three instances of
# that shipped in a consumer repo before mutation testing caught them. Anything
# asserting "this clause is in the skill" must assert it against the BODY.
#
# NO TOP-LEVEL SIDE EFFECTS — function definitions only, matching
# tests/_lib/git-sandbox.sh. Source it:
#   source "$(cd "$(dirname "$0")" && pwd)/_lib/skill-body.sh"

# Emit <file>'s content with its leading YAML frontmatter block stripped.
# Only the FIRST `---`-delimited block (starting at line 1) is treated as
# frontmatter; a later `---` horizontal rule in the body is preserved.
skill_body() {
  awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$1"
}

# True when <file>'s BODY contains the literal substring <needle>.
#
# NO PIPE — DELIBERATE, DO NOT "SIMPLIFY". Writing this as
#   skill_body "$1" <pipe> grep -qF -- "$2"
# makes `grep -q` exit on first match and SIGPIPE the upstream awk; under
# `set -o pipefail` the pipeline then returns 141 and a PRESENT anchor is
# reported ABSENT. Measured A/B under `set -euo pipefail`: the piped form
# produced 220 false-absents in 2800 calls, the form below 0 in 2800. A guard
# built on the piped form passes its own negative controls VACUOUSLY (a
# byte-identical no-op mutant was reported "caught" ~28 runs in 30).
#
# "$2" is quoted inside the case pattern, so glob metacharacters (`*`, `?`,
# `[`) in an anchor are matched literally.
skill_body_has() {
  case "$(skill_body "$1")" in
    *"$2"*) return 0 ;;
    *)      return 1 ;;
  esac
}
