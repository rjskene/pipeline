#!/bin/bash
# shellcheck shell=bash
# _high-uncertainty-match.sh — sourceable helper (issue #1039).
#
# Shared single source of truth for the high-uncertainty carve-out regex.
# Sourced by scripts/path-b-execute-eligible.sh (the #955 PATH B Sonnet-execute
# eligibility predicate) and scripts/plan-campaign.sh (the #838 campaign
# fold-select skip). Turns the old "can never drift" comment into a structural
# guarantee: both call sites read ONE pattern from here.
#
# Surgical word-bound: the proven-noisy short tokens (auth/race) are \b-anchored
# with explicit stems; the distinctive tokens stay substrings so
# cryptography/migrations/etc still match. The carve-out fails CLOSED to Opus —
# substring can only over-match, never under-match — so tightening is confined to
# where over-matching is proven noise (a too-tight regex would downshift
# genuinely risky work to Sonnet, a false negative).
#
# The bare lock stem (lock/locks/locking/locked) was DROPPED for `lock(ed)`
# polysemy (issue #1063): the concurrency-lock sense collides with benign
# meta-prose ("locked tests"/"locked suite"/"locked down"/"the file is locked"),
# the #1057 false-positive source. It is replaced by word-bounded concurrency
# PHRASES + `mutex`: \block contention\b, \block-free\b, \bfile lock\b, \bmutex\b.
# Word-bounding \bfile lock\b is load-bearing — it matches the concurrency
# MECHANISM ("a file lock") while the benign STATE ("the file is locked"/"file
# locked") does NOT. `deadlock` keeps matching as its own distinctive substring.
# This narrows ONLY proven-noise tokens, preserving the fail-CLOSED-to-Opus
# posture: genuine concurrency work (deadlock/lock contention/race/concurrency/
# mutex) still trips the carve-out.
#
# The auth stem enumerates the verb forms explicitly (authenticate/authorize) AND
# excludes the bare adjective "authentic":
#   \bauth(entication|enticate[ds]?|orization|orize[ds]?|n|z)?\b
# matches: auth, authn, authz, authentication, authenticate(s/d), authorization,
#          authorize(s/d)
# does NOT match: authoring, author, authored, authority, authentic
# A broader \bauth(entic\w*|oriz\w*|n|z)?\b WOULD wrongly match "authentic"
# (entic\w* consumes "entic" + an empty tail to a word boundary), violating the
# MUST-NOT contract row.
#
# This file is sourceable-only: a single assignment, no shebang side-effects.
HIGH_UNCERTAINTY_RE='concurrency|\bauth(entication|enticate[ds]?|orization|orize[ds]?|n|z)?\b|deadlock|\block contention\b|\block-free\b|\bfile lock\b|\bmutex\b|\brace(s)?\b|race condition|security|crypto|migration|data-loss'
