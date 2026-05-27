#!/bin/bash
set -euo pipefail

# Shared trust-filter helper for untrusted comment authors.
#
# Trust set = {OWNER, MEMBER, COLLABORATOR} (GitHub write access). Everything
# else — CONTRIBUTOR, NONE, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, unknown, empty
# — is untrusted.
#
# Modes:
#   filter-trusted-comments.sh is-trusted-author <association>
#       Low-level primitive. Exit 0 if trusted, 1 if not. Reused by #548/#549.

is_trusted_author() {
  case "${1:-}" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${1:-}" = "is-trusted-author" ]; then
  is_trusted_author "${2:-}"
  exit $?
fi
