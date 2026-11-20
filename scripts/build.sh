#!/bin/bash
# Plain (non-instrumented) build of the baseline tree: gpac's own configure/make
# with no sanitizer and no reproducer.  This is the build a static-analysis or
# repair tool can rely on; the instrumented builds live in verify*.sh.
#
#   GPDT_TREE=/src/gpac build.sh [--out DIR]
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tree=$TREE
out=${WORK:?}/plain-$(src_fp "$tree")
while [ $# -gt 0 ]; do
  case $1 in
    --tree) tree=${2:?}; shift 2 ;;
    --out)  out=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

[ -d "$tree" ] || die "no such source tree: $tree"
rm -rf "$out"; mkdir -p "$out"
( cd "$tree" && tar -cf - --exclude=./.git . ) | ( cd "$out" && tar -xf - )
cd "$out"
start=$(date +%s)
./configure --static-build > configure.log 2>&1 || { tail -n 20 configure.log; exit 1; }
make -j"$(nproc)" > make.log 2>&1 || { grep -m5 -E 'error:' make.log; tail -n 20 make.log; exit 1; }
[ -f bin/gcc/libgpac_static.a ] || die "no libgpac_static.a"
echo "built $out ($(( $(date +%s) - start ))s) — $(grep -m1 GPAC_VERSION config.mak | cut -d= -f2-)"
