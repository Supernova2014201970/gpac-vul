#!/bin/bash
# Every case, both sides, one build per case: the attribution check behind
# cases.tsv.  For each row it rebuilds the patched tree and asserts
#
#   baseline + PoC -> CRASH        (the bug is in the delivered tree)
#   patch    + PoC -> CLEAN        (this patch is what clears it)
#
#   verify-one-by-one.sh [--tree DIR] [--report DIR] [--case ID]...
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cases_file=${PAYLOAD:?}/cases.tsv
report_dir=/reports
want=()
while [ $# -gt 0 ]; do
  case $1 in
    --tree) TREE=${2:?}; shift 2 ;;
    --case) want+=("${2:?}"); shift 2 ;;
    --report) report_dir=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
mkdir -p "$report_dir"
json="$report_dir/verify-one-by-one.json"
printf '{\n  "src_fp": "%s",\n  "cases": [\n' "$(src_fp "$TREE")" > "$json"

first=1 pass=0 fail=0
while IFS=$'\t' read -r id rest; do
  [ -n "${id:-}" ] || continue
  case $id in \#*) continue ;; esac
  if [ ${#want[@]} -gt 0 ]; then
    printf '%s\n' "${want[@]}" | grep -qx "$id" || continue
  fi
  out=$("$GPDT_HOME/verify-one.sh" --case "$id" --tree "$TREE" --report "$report_dir" 2>&1)
  rc=$?
  [ $first -eq 1 ] || printf ',\n' >> "$json"; first=0
  printf '%s' "$(printf '%s\n' "$out" | grep -m1 '^{')" >> "$json"
  if [ $rc -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  printf '%s\n' "$out" | tail -n 2
done < <(awk -F'\t' '!/^#/ && NF >= 8 {print $1}' "$cases_file")

printf '\n  ],\n  "pass": %d,\n  "fail": %d\n}\n' "$pass" "$fail" >> "$json"
printf 'pass %d, fail %d\nreport: %s\n' "$pass" "$fail" "$json"
[ "$fail" -eq 0 ]
