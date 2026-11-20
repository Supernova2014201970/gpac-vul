#!/bin/bash
# One case, on one source tree: as-is (default) or that case's patch applied
# (--patched).
#
#   verify-one.sh <pocId> [--patched] [--report DIR] [--keep] [--tree DIR]
#
# --tree DIR — source tree to test; default /src/gpac (or $GPDT_TREE).
#   Default mode builds (cached) that tree and runs the case's PoC: the bug is
#   still there, so the sanitizer reports and pass is false.
# --patched — copy that tree to /work/one-<localId>, apply the case's single
#   patch (nothing else), build, run the same PoC.  pass is true when the
#   sanitizer no longer reports.  The source tree itself is never modified.
#
# `pass` means the same thing in every report this package writes: **the PoC did
# not crash the tree under test**.  Baseline -> false, patched -> true.  A run
# that neither crashed nor exited 0 is reported as CRASH too (pass=false): the
# report has no separate count for inconclusive runs.  GPDT_COLD=1 forces a full
# gpac rebuild for the patched tree instead of the incremental path.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

report=reports; ID=""; keep=0; patched=0; src=$TREE
while [ $# -gt 0 ]; do case "$1" in
  --report) report=${2:?}; shift 2 ;;
  --patched) patched=1; shift ;;
  --keep) keep=1; shift ;;
  --tree) src=${2:?}; shift 2 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  -*) die "unknown argument: $1" ;;
  *) [ -z "$ID" ] || die "only one pocId at a time"; ID=$1; shift ;;
esac; done
[ -n "$ID" ] || die "usage: verify-one.sh <pocId> [--patched] [--report DIR] [--keep] [--tree DIR]"
[ -d "$src" ] || die "no such source tree: $src"

row=$(awk -F'\t' -v id="$ID" '!/^#/ && $1 == id { print; exit }' "$PAYLOAD/cases.tsv")
[ -n "$row" ] || die "case '$ID' not found in $PAYLOAD/cases.tsv"
fuzzer=$(printf '%s\n' "$row" | cut -f2)
san=$(printf '%s\n' "$row" | cut -f3)
alert=$(printf '%s\n' "$row" | cut -f4)
poc=$(printf '%s\n' "$row" | cut -f6)
patch_file="$PAYLOAD/$(printf '%s\n' "$row" | cut -f7)"
patch=${patch_file#"$PAYLOAD/"}

tree="$src"; work=""; patched_fp=""
if [ "$patched" -eq 1 ]; then
  [ -f "$patch_file" ] || die "patch not found: $patch_file"
  work="$WORK/one-$ID"
  rm -rf "$work"; mkdir -p "$work" || die "cannot create $work"
  cp -a "$src/." "$work/" || die "cannot copy $src"
  # GNU patch, not `git apply`: the tree is a plain directory and file modes do
  # not survive a Windows bind mount, which makes git apply refuse every patch.
  ( cd "$work" && patch -p1 -s -i "$patch_file" ) || die "does not apply to $src: $patch"
  tree="$work"; patched_fp=$(src_fp "$work")
  # Clone the baseline build directory and let make rebuild only the objects the
  # patch touched (a case costs seconds instead of a full gpac build).
  if [ "${GPDT_COLD:-0}" != 1 ]; then
    GPDT_PATCH="$patch_file" GPDT_INCR_BASE="$src" export GPDT_PATCH GPDT_INCR_BASE
  fi
fi

bin=$(ensure_repro "$tree" "$san" "$fuzzer") || exit 1
out=$(run_poc "$san" "$bin" "$PAYLOAD/$poc")
status=CRASH; [ "${out%%$'\t'*}" = CLEAN ] && status=CLEAN

pass=false; [ "$status" = CLEAN ] && pass=true

mkdir -p "$report" || die "cannot create $report"
json="$report/verify-one.json"
{
  printf '{"pass": %s, "fail": %s, "results": [\n' \
    "$([ "$pass" = true ] && echo 1 || echo 0)" "$([ "$pass" = true ] && echo 0 || echo 1)"
  printf '  {"poc": "%s", "pass": %s, "alert": "%s"}' "$ID" "$pass" "$alert"
  printf '\n]}\n'
} > "$json.tmp" && mv -f "$json.tmp" "$json"

printf 'RESULT\t%s\t%s\t%s\n' "$ID" "$pass" "$alert"
printf '%-9s %-5s %-18s %-9s %s\n' "$ID" "$status" "$fuzzer" "$san" \
  "$([ "$patched" -eq 1 ] && echo "tree + ${patch#patches/}" || echo baseline)"
printf 'report  %s\n' "$json"
if [ -n "$work" ] && [ "$keep" -eq 0 ]; then
  rm -rf "$work"
  [ -n "$patched_fp" ] && rm -rf "$WORK/build-$patched_fp-$san"
fi
[ "$pass" = "$([ "$patched" -eq 1 ] && echo true || echo false)" ]
