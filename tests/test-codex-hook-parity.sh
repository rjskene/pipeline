#!/bin/bash
set -euo pipefail

# LINCHPIN parity test (issue #981) — enforcement cannot silently diverge
# between the two harnesses.
#
# Claude Code wires its PreToolUse/Stop enforcement hooks in
# .claude-plugin/plugin.json; Codex wires the SAME scripts under hooks/ in
# .codex/config.toml via the path-agnostic launcher (hooks/_run.sh <script>).
# This test parses BOTH manifests, normalizes the Edit/Write -> apply_patch
# matcher collapse, and asserts the two normalized SETS of
# (event, normalized-matcher, script-basename) tuples are EQUAL.
#
# Failure modes surfaced loudly:
#   - a script wired on one harness but not the other,
#   - a matcher mismatch for an otherwise-shared script.
#
# Parsers: plugin.json via json (stdlib); .codex/config.toml via tomllib
# (Python >=3.11) with a minimal [[hooks.X]] regex fallback. The .codex file
# ALSO carries an [mcp_servers.playwright] table — the parser ignores every
# non-hook table.
#
# Ground truth: the EXPECTED Claude Code tuple set is kept consistent with
# tests/test-plugin-hooks-registration.sh (the seven CC wirings). After the
# {Edit,Write} -> apply_patch collapse, the Codex side has six wirings.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
CODEX="$REPO_ROOT/.codex/config.toml"

for f in "$MANIFEST" "$CODEX"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required manifest not found: $f" >&2
    exit 1
  fi
done

python3 - "$MANIFEST" "$CODEX" <<'PY'
import json, re, sys

manifest_path, codex_path = sys.argv[1], sys.argv[2]

# --- Ground-truth Claude Code wiring (kept in lockstep with
#     tests/test-plugin-hooks-registration.sh). (event, matcher, filename). ---
EXPECTED_CC = [
    ("PreToolUse",  "Bash",  "block_deletions.py"),
    ("PreToolUse",  "Bash",  "enforce-base-branch.py"),
    ("PreToolUse",  "Bash",  "check-ci-skip-markers.py"),
    ("PreToolUse",  "Edit",  "enforce-path-c-delegation.py"),
    ("PreToolUse",  "Write", "enforce-path-c-delegation.py"),
    ("PreToolUse",  "*",     "restrict_paths.py"),
    ("Stop",        "*",     "enforce-ci-wait.py"),
]


def normalize_matcher(m):
    """Collapse the Claude Code {Edit,Write} file-mutation matchers onto the
    single Codex `apply_patch` token, so the two harnesses are comparable. All
    other matchers (Bash, *, apply_patch) pass through unchanged."""
    if m in ("Edit", "Write"):
        return "apply_patch"
    return m


def script_basename(cmd):
    """Reduce a hook command to the bare script basename, stripping the
    interpreter, ${CLAUDE_PLUGIN_ROOT}/hooks/ prefix, and the _run.sh launcher
    wrapper. Accepts both the CC string command and the Codex argv list."""
    if isinstance(cmd, list):
        parts = cmd
    else:
        parts = cmd.split()
    # Drop the _run.sh launcher token if present (Codex form).
    parts = [p for p in parts if not p.endswith("_run.sh")]
    # The script is the last token that ends in .py.
    for tok in reversed(parts):
        if tok.endswith(".py"):
            return tok.rsplit("/", 1)[-1]
    return ""


# --- Parse Claude Code plugin.json into the normalized tuple set. ---
def parse_cc(path):
    with open(path) as f:
        manifest = json.load(f)
    hooks = manifest.get("hooks", {})
    out = set()
    for event, entries in hooks.items():
        for entry in entries:
            matcher = entry.get("matcher")
            for cmd_obj in entry.get("hooks", []):
                base = script_basename(cmd_obj.get("command", ""))
                if base:
                    out.add((event, normalize_matcher(matcher), base))
    return out


# --- Parse Codex config.toml [[hooks.EVENT]] tables only. ---
def parse_codex(path):
    with open(path) as f:
        text = f.read()
    tables = None
    try:
        import tomllib
        data = tomllib.loads(text)
        hooks = data.get("hooks", {})
        tables = []
        for event, entries in hooks.items():
            # Each [[hooks.EVENT]] is an array-of-tables -> list of dicts.
            if isinstance(entries, list):
                for entry in entries:
                    tables.append((event, entry.get("matcher"), entry.get("command")))
    except ModuleNotFoundError:
        tables = None

    if tables is None:
        # Minimal regex fallback (Python <3.11): walk [[hooks.EVENT]] blocks,
        # ignoring any other table such as [mcp_servers.playwright].
        tables = []
        cur_event = None
        in_hook = False
        matcher = None
        command = None

        def flush():
            if in_hook and cur_event is not None:
                tables.append((cur_event, matcher, command))

        for raw in text.splitlines():
            line = raw.strip()
            m = re.match(r"^\[\[hooks\.([A-Za-z_]+)\]\]$", line)
            if m:
                flush()
                cur_event = m.group(1)
                in_hook = True
                matcher = None
                command = None
                continue
            # Any other table header ends the current hook block.
            if line.startswith("[") and not line.startswith("[["):
                flush()
                in_hook = False
                cur_event = None
                continue
            if line.startswith("[[") and not line.startswith("[[hooks."):
                flush()
                in_hook = False
                cur_event = None
                continue
            if not in_hook:
                continue
            mm = re.match(r'^matcher\s*=\s*"(.*)"\s*$', line)
            if mm:
                matcher = mm.group(1)
                continue
            cm = re.match(r"^command\s*=\s*(\[.*\])\s*$", line)
            if cm:
                command = [t.strip().strip('"') for t in
                           re.findall(r'"([^"]*)"', cm.group(1))]
                continue
        flush()

    out = set()
    for event, matcher, command in tables:
        base = script_basename(command if command is not None else "")
        if base:
            out.add((event, normalize_matcher(matcher), base))
    return out


cc_expected = {(e, normalize_matcher(m), f) for (e, m, f) in EXPECTED_CC}
cc_actual = parse_cc(manifest_path)
codex_actual = parse_codex(codex_path)

PASS = 0
FAIL = 0
fails = []


def check(desc, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS: {desc}")
    else:
        FAIL += 1
        fails.append(desc)
        print(f"  FAIL: {desc} — {detail}")


# 1. The CC manifest must match the ground-truth EXPECTED set used by
#    tests/test-plugin-hooks-registration.sh (after normalization). This keeps
#    the parity test honest: if plugin.json drifts, EXPECTED_CC must move too.
check(
    "plugin.json normalized wiring == EXPECTED_CC ground truth",
    cc_actual == cc_expected,
    f"plugin.json-only={sorted(cc_actual - cc_expected)} "
    f"expected-only={sorted(cc_expected - cc_actual)}",
)

# 2. THE LINCHPIN: the normalized Codex set must equal the normalized CC set.
only_codex = sorted(codex_actual - cc_expected)
only_cc = sorted(cc_expected - codex_actual)
check(
    "normalized Codex wiring SET == normalized Claude Code wiring SET",
    codex_actual == cc_expected,
    f"wired-on-Codex-only={only_codex} wired-on-CC-only={only_cc}",
)

# 3. Every ground-truth enforcement SCRIPT appears on the Codex side (basename
#    coverage), independent of matcher — a sharper message when a whole script
#    is missing vs. a matcher typo.
cc_scripts = {f for (_, _, f) in cc_expected}
codex_scripts = {f for (_, _, f) in codex_actual}
check(
    "every Claude Code enforcement script is wired under Codex",
    cc_scripts <= codex_scripts,
    f"missing-on-Codex={sorted(cc_scripts - codex_scripts)}",
)

# 4. The Codex side introduces no enforcement script the CC side lacks.
check(
    "Codex wires no enforcement script absent from Claude Code",
    codex_scripts <= cc_scripts,
    f"extra-on-Codex={sorted(codex_scripts - cc_scripts)}",
)

print(f"RESULT: {PASS} passed, {FAIL} failed")
if FAIL:
    print("DIVERGENCE: enforcement wirings are NOT in parity across harnesses.")
sys.exit(0 if FAIL == 0 else 1)
PY
