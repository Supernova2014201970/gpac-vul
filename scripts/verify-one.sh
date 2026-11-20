#!/bin/bash
# One case, both sides: the PoC must crash the baseline and go quiet once the
# case's patch is applied.
#
#   verify-one.sh --case ID [--tree DIR] [--report DIR]
#
# The patched tree is a copy of the baseline under /work with payload/patches/
# <ID>.patch applied by `git apply`; it gets its own fingerprint, so it is built
# into its own /work/build-* directory and never shares objects with the
# baseline build.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cases_file=${PAYLOAD:?}/cases.tsv
report_dir=/reports
id="" 
while [ $# -gt 0 ]; do
  case $1 in
    --case) id=${2:?}; shift 2 ;;
    --tree) TREE=${2:?}; shift 2 ;;
    --report) report_dir=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$id" ] || die "usage: verify-one.sh --case ID"
mkdir -p "$report_dir"

row=$(awk -F'\t' -v id="$id" '$1 == id {print}' "$cases_file")
[ -n "$row" ] || die "case $id not in $cases_file"
IFS=$'\t' read -r _ target san expect poc patch fix <<< "$row"
[ -f "$PAYLOAD/$poc" ] || die "missing PoC $PAYLOAD/$poc"
[ -f "$PAYLOAD/$patch" ] || die "missing patch $PAYLOAD/$patch"

# Baseline side: the bug must be there.
base_bin=$(ensure_repro "$TREE" "$san" "$target") || exit 1
IFS=$'\t' read -r b_verdict b_summary <<< "$(run_poc "$san" "$base_bin" "$PAYLOAD/$poc")"

# Patched side.
patched="$WORK/case-$id"
rm -rf "$patched"; mkdir -p "$patched"
( cd "$TREE" && tar -cf - --exclude=./.git . ) | ( cd "$patched" && tar -xf - ) ||
  die "cannot copy $TREE"
# GNU patch, not `git apply`: the tree is a plain directory and file modes do
# not survive a Windows bind mount, which makes git apply refuse every patch.
( cd "$patched" && patch -p1 -s -i "$PAYLOAD/$patch" ) || die "patch $patch does not apply"
# GPDT_COLD=1 forces the cold build path (full gpac compile) instead of
# cloning the baseline build directory; used to cross-check a verdict.
if [ "${GPDT_COLD:-0}" = 1 ]; then
  p_bin=$(ensure_repro "$patched" "$san" "$target") || exit 1
else
  GPDT_PATCH="$PAYLOAD/$patch" GPDT_INCR_BASE="$TREE" \
    p_bin=$(ensure_repro "$patched" "$san" "$target") || exit 1
fi
IFS=$'\t' read -r p_verdict p_summary <<< "$(run_poc "$san" "$p_bin" "$PAYLOAD/$poc")"

pass=false
[ "$b_verdict" = "CRASH" ] && [ "$p_verdict" = "CLEAN" ] && pass=true
# JSON-safe: sanitizer summaries carry quotes, backslashes and tabs.
jstr() { printf '%s' "$1" | tr -d '\r' | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf '{"case": %s, "patch": "%s", "sanitizer": "%s", "target": "%s", "baseline": {"verdict": "%s", "summary": "%s"}, "patched": {"verdict": "%s", "summary": "%s"}, "pass": %s}\n' \
  "$id" "$patch" "$san" "$target" "$b_verdict" "$(jstr "$b_summary")" "$p_verdict" "$(jstr "$p_summary")" "$pass" \
  > "$report_dir/one-$id.json"
printf '%-10s baseline %-6s patched %-6s %s\n' "$id" "$b_verdict" "$p_verdict" \
  "$([ "$pass" = true ] && echo PASS || echo FAIL) — $p_summary"
printf 'report: %s\n' "$report_dir/one-$id.json"
# Drop this case's build tree: the reproducer in /out is cached by fingerprint, so
# a re-run skips the build, and 33 copies of a half-gigabyte tree would not fit.
rm -rf "$WORK/build-$(src_fp "$patched")-$san"
[ "$pass" = true ]
