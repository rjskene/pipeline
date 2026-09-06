#!/usr/bin/env bash
# case-validate.sh — unit tests for lib/validate.sh.
. "$(dirname "$0")/helper.sh"
t_setup

# shellcheck source=../lib/store.sh
. "$PROJECT_ROOT/lib/store.sh"
# shellcheck source=../lib/lock.sh
. "$PROJECT_ROOT/lib/lock.sh"
# shellcheck source=../lib/validate.sh
. "$PROJECT_ROOT/lib/validate.sh"

check() {
  local fn="$1" value="$2" want_rc="$3" label="$4"
  local rc=0
  "$fn" "$value" >/dev/null 2>&1 || rc=$?
  assert_rc "$want_rc" "$rc" "$label"
}

check validate_title "write docs" 0 "a normal title is accepted"
check validate_title "" 2 "an empty title is rejected"
check validate_title "   " 2 "a whitespace-only title is rejected"
check validate_title "$(printf 'x%.0s' $(seq 1 200))" 2 "an over-long title is rejected"

check validate_priority low 0 "priority low is accepted"
check validate_priority med 0 "priority med is accepted"
check validate_priority high 0 "priority high is accepted"
check validate_priority urgent 2 "priority urgent is rejected"
check validate_priority "" 2 "an empty priority is rejected"

check validate_status open 0 "status open is accepted"
check validate_status done 0 "status done is accepted"
check validate_status all 0 "status all is accepted"
check validate_status pending 2 "status pending is rejected"

check validate_id 1 0 "id 1 is accepted"
check validate_id 4711 0 "id 4711 is accepted"
check validate_id abc 2 "a purely alphabetic id is rejected"
check validate_id "" 2 "an empty id is rejected"

check validate_tags "docs,ops" 0 "a comma-separated tag list is accepted"
check validate_tags "" 0 "an empty tag list is accepted"
check validate_tags "docs ops" 2 "a tag list with spaces is rejected"

msg="$(validate_priority nope 2>&1)"
assert_contains "$msg" "invalid priority" "rejection messages name the field"

t_report
