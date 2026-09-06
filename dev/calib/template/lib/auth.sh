# shellcheck shell=bash
#
# auth.sh — the API-token helper.
#
# calibctl talks to an (imaginary) remote ledger service with a bearer token
# held in <store home>/auth.token. Tokens are 32 lowercase hex characters.
#
# CALIB_AUTH_SLOW is a test seam: when set to a number of seconds, the write
# path pauses for that long in the middle of publishing the token. It exists so
# the suite can observe what a concurrent reader sees while a token is being
# rotated, without depending on scheduler luck.
#
# Depends on lib/store.sh (store_home) and lib/lock.sh (locking); source those
# first.

CALIB_RC_AUTH=6

auth_token_path() {
  printf '%s\n' "${CALIB_TOKEN_FILE:-$(store_home)/auth.token}"
}

auth__delay() {
  local seconds="${CALIB_AUTH_SLOW:-}"
  if [ -n "$seconds" ]; then
    sleep "$seconds"
  fi
  return 0
}

auth_mint_token() {
  local raw
  raw="$(date '+%s%N')$$${RANDOM:-0}"
  printf '%s' "$raw" | md5sum | cut -c1-32
}

# auth_issue_token — mint a fresh token, publish it, and echo it.
auth_issue_token() {
  local token file
  file="$(auth_token_path)"
  mkdir -p "$(dirname "$file")"
  token="$(auth_mint_token)"
  : > "$file"
  auth__delay
  printf '%s\n' "$token" >> "$file"
  chmod 600 "$file" 2>/dev/null || true
  printf '%s\n' "$token"
}

# auth_read_token — echo the current token, rc CALIB_RC_AUTH when absent.
auth_read_token() {
  local file token
  file="$(auth_token_path)"
  [ -f "$file" ] || return "$CALIB_RC_AUTH"
  token="$(head -n1 "$file")"
  [ -n "$token" ] || return "$CALIB_RC_AUTH"
  printf '%s\n' "$token"
}

auth_revoke_token() {
  local file
  file="$(auth_token_path)"
  [ -f "$file" ] || return "$CALIB_RC_AUTH"
  rm -f "$file"
}

auth_token_valid() {
  local token="$1"
  [[ "$token" =~ ^[0-9a-f]{32}$ ]]
}
