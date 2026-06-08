#!/usr/bin/env bash
# _run.sh — path-agnostic hook launcher (issue #981, Leg 2 of the Codex
# dual-target migration).
#
# The committed .codex/config.toml registers PreToolUse hooks but MUST NOT carry
# host-specific absolute paths (the repo is cloned/bundled to different roots per
# operator). This launcher resolves the plugin root at run time and execs the
# named hook under it, so config.toml can reference hooks by bare script name:
#
#     hooks/_run.sh restrict_paths.py
#
# Resolution mirrors the boot-anchor pattern in scripts/_resolve-plugin-root.sh:
# honor an already-exported CLAUDE_PLUGIN_ROOT; otherwise source the resolver
# relative to THIS file (a var-independent anchor — we cannot reference
# CLAUDE_PLUGIN_ROOT to find the tree that defines it).
#
# Contract:
#   - stdin is forwarded to the hook (exec preserves fd 0).
#   - the hook's exit code propagates to the caller (exec replaces this process),
#     so the Claude Code / Codex PreToolUse contract (exit 2 = block) is intact.
set -euo pipefail

script="${1:?_run.sh: missing hook script name}"
shift

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  # Resolve relative to _run.sh itself — the resolver lives one dir up under
  # scripts/. It exports CLAUDE_PLUGIN_ROOT (or leaves it unset on a consumer
  # host with no cache, in which case the exec fallback below uses $HERE/..).
  . "$HERE/../scripts/_resolve-plugin-root.sh"
fi

exec python3 "${CLAUDE_PLUGIN_ROOT:-$HERE/..}/hooks/$script" "$@"
