#!/usr/bin/env bash
# case-ids.sh — concurrent `calibctl add` calls each get their own task id.
. "$(dirname "$0")/helper.sh"
t_setup

N=10
outdir="$(mktemp -d)"

i=1
while [ "$i" -le "$N" ]; do
  calib add "concurrent task $i" > "$outdir/$i.out" 2>&1 &
  i=$((i + 1))
done
wait

ids="$(cat "$outdir"/*.out)"
rm -rf "$outdir"

distinct="$(printf '%s\n' "$ids" | grep -E '^[0-9]+$' | sort -u | grep -c '')"
assert_eq "$N" "$distinct" "$N concurrent adds return $N distinct ids"

rows="$(grep -c '' "$CALIB_HOME/tasks.tsv")"
assert_eq "$N" "$rows" "$N concurrent adds write $N ledger rows"

ledger_ids="$(cut -f1 "$CALIB_HOME/tasks.tsv" | sort -u | grep -c '')"
assert_eq "$N" "$ledger_ids" "every ledger row carries its own id"

t_report
