#!/bin/bash
set -uo pipefail
#
# Tests for scripts/visual-proof-server-start.sh — the single-responsibility
# bootstrap that composes visual-proof-port-broker.sh to allocate a port, then
# starts a loopback `python3 -m http.server --directory <target> --bind
# 127.0.0.1`, readiness-probes it, and emits a parseable
#   SERVER: pid=<P> port=<PORT> dir=<dir>
# line. Reusable entry point for the single-issue orchestrator path, manual
# operators, and the evaluate-issue-pr inline path (Step 6c). See Issue #527
# (PR #519 follow-up). Auto-discovered by the tests/test*.sh glob.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STARTER="$REPO_ROOT/scripts/visual-proof-server-start.sh"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- Case (a): argument validation — missing/nonexistent target_dir -> exit 2 ----

# (a1) no args -> exit 2
bash "$STARTER" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass_msg "no args -> exit 2 (got: $rc)" || fail_msg "no args -> exit 2 (got: $rc)"

# (a2) slate_index present but target_dir missing -> exit 2
bash "$STARTER" 0 >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass_msg "missing target_dir -> exit 2 (got: $rc)" || fail_msg "missing target_dir -> exit 2 (got: $rc)"

# (a3) nonexistent target_dir -> exit 2
bash "$STARTER" 0 "/no/such/dir/$$" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && pass_msg "nonexistent target_dir -> exit 2 (got: $rc)" || fail_msg "nonexistent target_dir -> exit 2 (got: $rc)"

# ---- Case (b): happy path — real temp dir served; SERVER: line parseable; curl 200; pid alive ----
TMP_B=$(mktemp -d)
echo "hello-527" > "$TMP_B/index.html"
out=$(PIPELINE_VISUAL_PROOF_PORT_BASE=8400 bash "$STARTER" 7 "$TMP_B" 2>/dev/null)
# SERVER: pid=<P> port=<PORT> dir=<dir>
spid=$(printf '%s\n' "$out" | sed -n 's/^SERVER: pid=\([0-9]*\) .*/\1/p')
sport=$(printf '%s\n' "$out" | sed -n 's/^SERVER: .*port=\([0-9]*\) .*/\1/p')
sdir=$(printf '%s\n' "$out" | sed -n 's/^SERVER: .*dir=\(.*\)$/\1/p')
ok=1
[ -n "$spid" ] && kill -0 "$spid" 2>/dev/null || ok=0
[ "$sport" = "8407" ] || ok=0          # 8400 + slate_index 7, slate_width omitted -> 0 dispersion
[ "$sdir" = "$TMP_B" ] || ok=0
curl --silent --fail --max-time 5 "http://127.0.0.1:$sport/" | grep -q "hello-527" || ok=0
[ "$ok" = "1" ] && pass_msg "happy path: SERVER line + reachable server (pid=$spid port=$sport)" \
                 || fail_msg "happy path: SERVER line + reachable server (out=$out)"
[ -n "$spid" ] && kill "$spid" 2>/dev/null
rm -rf "$TMP_B"

# ---- Case (c): port composition — PORT_BASE + slate_index reflected (slate_width omitted -> deterministic) ----
TMP_C=$(mktemp -d); echo x > "$TMP_C/index.html"
out=$(PIPELINE_VISUAL_PROOF_PORT_BASE=9300 bash "$STARTER" 5 "$TMP_C" 2>/dev/null)
sport=$(printf '%s\n' "$out" | sed -n 's/^SERVER: .*port=\([0-9]*\) .*/\1/p')
spid=$(printf '%s\n' "$out" | sed -n 's/^SERVER: pid=\([0-9]*\) .*/\1/p')
[ "$sport" = "9305" ] && pass_msg "port composition: PORT_BASE 9300 + slate_index 5 -> 9305 (got: $sport)" \
                      || fail_msg "port composition: PORT_BASE 9300 + slate_index 5 -> 9305 (got: $sport)"
[ -n "$spid" ] && kill "$spid" 2>/dev/null
rm -rf "$TMP_C"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
