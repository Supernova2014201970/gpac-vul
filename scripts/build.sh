#!/bin/bash
# Plain (non-instrumented) build of the baseline tree: gpac's own configure and
# make, no sanitizer and no reproducer.  This is the build a static-analysis or
# repair tool can drive; the instrumented builds live in verify*.sh.
#
#   build.sh [--tree DIR]         default: /src/gpac
#
# The tree is copied out first, so the baseline stays byte-identical.  The
# configuration is the same headless one the verification builds use
# (lib.sh:headless_configure), which is what makes bin/gcc/libgpac_static.a
# buildable in this image.  Re-running rebuilds from scratch.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tree=$TREE
while [ $# -gt 0 ]; do
  case $1 in
    --tree) tree=${2:?--tree needs a directory}; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    -*) die "unknown argument $1" ;;
    *) tree=$1; shift ;;
  esac
done

[ -d "$tree" ] || die "no such source tree: $tree"
[ -f "$tree/configure" ] || die "$tree/configure missing (it is tracked)"

out="$WORK/plain-$(src_fp "$tree")"
rm -rf "$out"; mkdir -p "$out"
( cd "$tree" && tar -cf - --exclude=./.git . ) | ( cd "$out" && tar -xf - ) ||
  die "cannot copy $tree"
cd "$out"

start=$(date +%s)
headless_configure "$out" "$(plain_flags)" "$out/configure.log" || exit 1
make -j"${MAKE_JOBS:-4}" > make.log 2>&1 || { grep -m5 -E 'error:' make.log; tail -n 20 make.log; exit 1; }
[ -f bin/gcc/libgpac_static.a ] || die "no bin/gcc/libgpac_static.a after make"
echo "built $out ($(( $(date +%s) - start ))s): $(stat -c %s bin/gcc/libgpac_static.a) bytes of libgpac_static.a"
