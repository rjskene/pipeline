#!/bin/bash
# shellcheck shell=bash
# _trust-profile.sh — sourceable helper (issue #1291).
#
# Shared single source of truth for PIPELINE_TRUST_PROFILE, the one knob that
# selects how much redundant verification the pipeline buys per issue:
#
#   strict (the DEFAULT) — the pre-#1291 shape, byte-for-byte. Every read-site
#     behaves exactly as it did before this helper existed.
#   lean — trade redundant verification for cost where the remaining dispatch is
#     still a strong model: collapse the #881 split-role PAIR into ONE dispatch
#     (scripts/resolve-execute-dispatch.sh), and skip the PATH A/D plan-eval
#     second opinion (scripts/resolve-stage-model.sh).
#
# Both resolvers source THIS file so the profile is normalized in exactly ONE
# place. Read-sites consume $TRUST_PROFILE and must NEVER re-normalize
# ${PIPELINE_TRUST_PROFILE} themselves — a second normalization is a second
# source of truth, which is the #1039/#1056 drift failure mode.
#
# FAIL-SAFE: an unrecognized value falls back to `strict` with ONE warning on
# stderr. A typo'd knob must never silently buy a cheaper (less verified) shape,
# and the WARN must never contaminate stdout — the resolvers' stdout is a
# machine-parsed token block.
#
# `set -u` safe: every read uses a :- default.

_tp_raw="${PIPELINE_TRUST_PROFILE:-strict}"
case "$_tp_raw" in
  strict|lean)
    TRUST_PROFILE="$_tp_raw"
    ;;
  *)
    echo "WARN: PIPELINE_TRUST_PROFILE='$_tp_raw' is not strict|lean — falling back to strict" >&2
    TRUST_PROFILE="strict"
    ;;
esac
unset _tp_raw
