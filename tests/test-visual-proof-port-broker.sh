#!/bin/bash
set -uo pipefail
#
# Tests for scripts/visual-proof-port-broker.sh — the single-purpose port
# broker that allocates a host port for inline browser-eval `python3 -m
# http.server` instances. See Issue #517.
#
# Argv contract:
#   bash visual-proof-port-broker.sh <slate_index> [<slate_width>]
#
# Env:
#   PIPELINE_VISUAL_PROOF_PORT_BASE — default 8080.
#
# Output:
#   PORT=<n> on stdout.
#
# Formula:
#   PORT = PORT_BASE + slate_index + (PID_LOW_BITS % 100) * slate_width
#   where PID_LOW_BITS = $$ & 0xFFFF.
#   PID term collapses to 0 when slate_width is omitted or 0.
#
# Asserts:
#   (a) defaults — PORT_BASE unset, slate_index=0 → PORT=8080
#   (b) PORT_BASE=9100, slate_index=3 → PORT=9103 when slate_width omitted
#   (c) PID dispersion deterministic — same script PID yields same PORT
#   (d) negative slate_index → exit 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BROKER="$REPO_ROOT/scripts/visual-proof-port-broker.sh"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# (a) Defaults: PORT_BASE unset, slate_index=0 → PORT=8080
if [ -f "$BROKER" ]; then
  out=$(unset PIPELINE_VISUAL_PROOF_PORT_BASE; bash "$BROKER" 0 2>/dev/null)
  if [ "$out" = "PORT=8080" ]; then
    pass_msg "defaults: PORT_BASE unset, slate_index=0 → PORT=8080 (got: $out)"
  else
    fail_msg "defaults: PORT_BASE unset, slate_index=0 → PORT=8080 (got: $out)"
  fi
else
  fail_msg "broker exists at scripts/visual-proof-port-broker.sh"
fi

# (b) PORT_BASE=9100, slate_index=3, slate_width omitted → PORT=9103
if [ -f "$BROKER" ]; then
  out=$(PIPELINE_VISUAL_PROOF_PORT_BASE=9100 bash "$BROKER" 3 2>/dev/null)
  if [ "$out" = "PORT=9103" ]; then
    pass_msg "PORT_BASE=9100, slate_index=3, no slate_width → PORT=9103 (got: $out)"
  else
    fail_msg "PORT_BASE=9100, slate_index=3, no slate_width → PORT=9103 (got: $out)"
  fi
fi

# (b2) explicit slate_width=0 also collapses PID term
if [ -f "$BROKER" ]; then
  out=$(PIPELINE_VISUAL_PROOF_PORT_BASE=9100 bash "$BROKER" 3 0 2>/dev/null)
  if [ "$out" = "PORT=9103" ]; then
    pass_msg "PORT_BASE=9100, slate_index=3, slate_width=0 → PORT=9103 (got: $out)"
  else
    fail_msg "PORT_BASE=9100, slate_index=3, slate_width=0 → PORT=9103 (got: $out)"
  fi
fi

# (c) PID dispersion deterministic — same script PID yields same PORT.
# We assert two properties:
#   1. Range: two back-to-back invocations both produce ports in the
#      documented [PORT_BASE+slate_index, PORT_BASE+slate_index+99*slate_width]
#      range. (Different PIDs each call, so we can't compare equality.)
#   2. Determinism-given-PID: when we capture the broker's $$ via an
#      `exec` wrapper (which fixes $$ to the wrapper's PID), the emitted
#      PORT matches PORT_BASE + slate_index + ($$ & 0xFFFF) % 100 *
#      slate_width exactly.
if [ -f "$BROKER" ]; then
  out1=$(PIPELINE_VISUAL_PROOF_PORT_BASE=10000 bash "$BROKER" 2 5 2>/dev/null)
  out2=$(PIPELINE_VISUAL_PROOF_PORT_BASE=10000 bash "$BROKER" 2 5 2>/dev/null)
  port1="${out1#PORT=}"
  port2="${out2#PORT=}"
  low=$((10000 + 2))
  high=$((10000 + 2 + 99 * 5))
  if [ "$port1" -ge "$low" ] && [ "$port1" -le "$high" ] \
     && [ "$port2" -ge "$low" ] && [ "$port2" -le "$high" ]; then
    pass_msg "PID dispersion in documented range [$low, $high] (got: $port1, $port2)"
  else
    fail_msg "PID dispersion in documented range [$low, $high] (got: $port1, $port2)"
  fi

  # Determinism-given-PID: redirect broker output to a temp file via a
  # bash -c wrapper that uses `exec`. `exec bash BROKER >FILE` replaces
  # the wrapper shell with the broker process at the same PID, so the
  # broker's $$ equals the captured PID from before exec. We do this
  # twice; each run should yield a port matching the formula evaluated
  # with that run's PID. Both runs assert the deterministic-given-PID
  # property independently.
  TMP_PID=$(mktemp)
  TMP_OUT=$(mktemp)
  PIPELINE_VISUAL_PROOF_PORT_BASE=10000 bash -c '
    echo $$ > "'"$TMP_PID"'"
    exec bash "'"$BROKER"'" 2 5 > "'"$TMP_OUT"'"
  ' 2>/dev/null
  pid=$(cat "$TMP_PID")
  out=$(cat "$TMP_OUT")
  port="${out#PORT=}"
  low_bits=$((pid & 0xFFFF))
  expected=$((10000 + 2 + (low_bits % 100) * 5))
  if [ "$port" = "$expected" ]; then
    pass_msg "PID-determinism: broker output matches formula given exec'd PID (port=$port pid=$pid)"
  else
    fail_msg "PID-determinism: broker output matches formula given exec'd PID (port=$port expected=$expected pid=$pid)"
  fi

  # Second run, same wrapper shape — independent PID, but again should
  # satisfy the formula. Asserts the formula isn't sensitive to other
  # state.
  PIPELINE_VISUAL_PROOF_PORT_BASE=10000 bash -c '
    echo $$ > "'"$TMP_PID"'"
    exec bash "'"$BROKER"'" 2 5 > "'"$TMP_OUT"'"
  ' 2>/dev/null
  pid=$(cat "$TMP_PID")
  out=$(cat "$TMP_OUT")
  port="${out#PORT=}"
  low_bits=$((pid & 0xFFFF))
  expected=$((10000 + 2 + (low_bits % 100) * 5))
  if [ "$port" = "$expected" ]; then
    pass_msg "PID-determinism (run 2): broker output matches formula given exec'd PID (port=$port pid=$pid)"
  else
    fail_msg "PID-determinism (run 2): broker output matches formula given exec'd PID (port=$port expected=$expected pid=$pid)"
  fi
  rm -f "$TMP_PID" "$TMP_OUT"
fi

# (d) Negative slate_index → exit 2
if [ -f "$BROKER" ]; then
  bash "$BROKER" -1 >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "2" ]; then
    pass_msg "negative slate_index → exit 2 (got: $rc)"
  else
    fail_msg "negative slate_index → exit 2 (got: $rc)"
  fi
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
