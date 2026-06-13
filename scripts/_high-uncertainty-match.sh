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
# Surgical word-bound: ONLY the three proven-noisy short tokens (auth/lock/race)
# are \b-anchored with explicit stems; the distinctive tokens stay substrings so
# cryptography/migrations/etc still match. The carve-out fails CLOSED to Opus —
# substring can only over-match, never under-match — so tightening is confined to
# where over-matching is proven noise (a too-tight regex would downshift
# genuinely risky work to Sonnet, a false negative).
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
HIGH_UNCERTAINTY_RE='concurrency|\bauth(entication|enticate[ds]?|orization|orize[ds]?|n|z)?\b|\block(s|ing|ed)?\b|deadlock|\brace(s)?\b|security|crypto|migration|data-loss'
