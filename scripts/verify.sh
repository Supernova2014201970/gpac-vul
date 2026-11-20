#!/bin/bash
# Baseline verification: every shipped PoC must still crash the unpatched tree.
#
#   verify.sh [--tree DIR] [--case ID]... [--report DIR] [--json]
#
# Builds the instrumented reproducer for each (target, sanitizer) pair the case
# table uses, runs each PoC once under the sanitizer that reported it, and writes
# <report>/verify.json.  Exits non-zero unless every case reports CRASH — a
# silent change in the baseline, in a PoC or in the table fails loudly here.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cases_file=${PAYLOAD:?}/cases.tsv
report_dir=${OUT:?}/../reports
[ -d "$OUT/../reports" ] || report_dir=/reports
want=()
while [ $# -gt 0 ]; do
  case $1 in
    --tree) TREE=${2:?}; shift 2 ;;
    --case) want+=("${2:?}"); shift 2 ;;
    --report) report_dir=${2:?}; shift 2 ;;
    --json) shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -f "$cases_file" ] || die "missing case table $cases_file"
mkdir -p "$report_dir"

rows=$(awk -F'\t' '!/^#/ && NF >= 8 {print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8}' "$cases_file")
json="$report_dir/verify.json"
{
  printf '{\n  "base": "%s",\n  "src_fp": "%s",\n  "cases": [\n' "$TREE" "$(src_fp "$TREE")"
} > "$json"

first=1 notcrash=0 total=0
while IFS=$'\t' read -r id target san expect poc patch fix; do
  [ -n "${id:-}" ] || continue
  [ -f "$PAYLOAD/$poc" ] || die "missing PoC $PAYLOAD/$poc"
  if [ ${#want[@]} -gt 0 ]; then
    printf '%s\n' "${want[@]}" | grep -qx "$id" || continue
  fi
  bin=$(ensure_repro "$TREE" "$san" "$target") || exit 1
  IFS=$'\t' read -r verdict summary <<< "$(run_poc "$san" "$bin" "$PAYLOAD/$poc")"
  total=$((total + 1))
  [ "$verdict" = "$expect" ] || notcrash=$((notcrash + 1))
  [ $first -eq 1 ] || printf ',\n' >> "$json"; first=0
  printf '    {"case": %s, "target": "%s", "sanitizer": "%s", "verdict": "%s", "expected": "%s", "summary": %s}' \
    "$id" "$target" "$san" "$verdict" "$expect" "$(printf '%s' "$summary" | tr -d '\r' | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')" >> "$json"
  printf '%-10s %-20s %-9s %-6s %s\n' "$id" "$target" "$san" "$verdict" "${summary:0:60}"
done <<< "$rows"

printf '\n  ]\n}\n' >> "$json"
printf '%d cases, %d not %s\n' "$total" "$notcrash" "${expect:-CRASH}"
printf 'report: %s\n' "$json"
[ "$notcrash" -eq 0 ]
