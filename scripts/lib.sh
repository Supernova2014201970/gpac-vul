#!/bin/bash
# Shared helpers for the gpac ARVO dataset: one baseline tree, one patch per
# case, one reproducer per (source fingerprint, sanitizer).
#
# /src/gpac              upstream b890f1c443dbe1f941cd326d4473ce7ddef8e256
#                        (the parent of the first fix in the window), plain
#                        checkout without .git — same bytes as src/gpac-readonly
# /payload               cases.tsv, pocs/, patches/, vulnerabilities.json
# /out/repro-<fp>-<san>  instrumented fuzzer (fuzz_probe_analyze / fuzz_parse)
# /work/build-<fp>-<san> private build tree; libgpac_static.a is used in place
#
# <fp> is the source fingerprint (content hash of the tree plus, for a git tree,
# HEAD and the sha256 of `git diff`), so the baseline and every patched copy get
# their own build directory without collisions.
set -uo pipefail

GPDT_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=${GPDT_TREE:-/src/gpac}
PAYLOAD=${PAYLOAD:-/payload}
OUT=${OUT:-/out}
WORK=${WORK:-/work}

die() { echo "error: $*" >&2; exit 1; }
ulimit -c 0 2>/dev/null || true   # a sanitizer crash must not leave core files

# The 39 cases were found by two OSS-Fuzz runs of the same gpac build: ASan (30)
# and UBSan (9).  Each PoC is replayed under the sanitizer that reported it.
san_profile() { case "$1" in
  address|asan)    echo address ;;
  undefined|ubsan) echo undefined ;;
  *) die "unknown sanitizer '$1' (address|undefined)" ;;
esac; }

# The environment the OSS-Fuzz runner uses for each profile.
san_env() { case "$1" in
  address|asan) echo "ASAN_OPTIONS=alloc_dealloc_mismatch=0:allocator_may_return_null=1:check_malloc_usable_size=0:detect_container_overflow=1:detect_leaks=0:detect_odr_violation=0:detect_stack_use_after_return=1:fast_unwind_on_fatal=0:handle_abort=1:handle_segv=1:handle_sigill=1:print_scariness=1:quarantine_size_mb=10:strict_memcmp=1:symbolize=1:use_sigaltstack=1:dedup_token_length=3" ;;
  undefined|ubsan) echo "UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:symbolize=1:halt_on_error=1:dedup_token_length=3" ;;
  *) die "unknown sanitizer '$1'" ;;
esac; }

# OSS-Fuzz's gpac build adds -fwrapv (deterministic signed overflow) and, for the
# UBSan run, drops the integer-overflow checks so only real faults are reported.
san_flags() { case "$1" in
  address|asan)    echo "-fsanitize=address -fsanitize-address-use-after-scope" ;;
  undefined|ubsan) echo "-fsanitize=undefined -fno-sanitize-recover=undefined -fno-sanitize=unsigned-integer-overflow,signed-integer-overflow" ;;
  *) die "unknown sanitizer '$1'" ;;
esac; }

# Flags both the instrumented and the plain build use.
plain_flags() {
  echo "-O1 -gline-tables-only -fno-omit-frame-pointer -fwrapv -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
}

# Source fingerprint of a git work tree, or a content hash for a plain copy
# without history (src/gpac-readonly as shipped, or any --tree DIR that is not a
# git checkout).
src_fp() {
  local dir=$1 commit
  if commit=$(git -C "$dir" rev-parse HEAD 2>/dev/null); then
    printf '%s-%s' "${commit:0:8}" "$(git -C "$dir" diff | sha256sum | cut -c1-8)"
  else
    ( cd "$dir" && find . -path ./.git -prune -o -type f -print0 |
        LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16 ) |
      { read -r hash; printf 'tree-%s' "$hash"; }
  fi
}

# run_poc <san> <binary> <poc> -> "<verdict><TAB><summary>"
#
#   CRASH  the sanitizer reported — the bug is present
#   CLEAN  exit status 0 and no report — the bug is gone
#   ERROR  neither: no report but the process did not exit 0
run_poc() {
  local san=$1 bin=$2 poc=$3 out sum rc envs
  [ -x "$bin" ] || die "missing reproducer $bin (run: verify.sh)"
  [ -f "$poc" ] || die "missing PoC $poc"
  envs=$(san_env "$san")
  out=$(env $envs "$bin" "$poc" 2>&1) 2>/dev/null
  rc=$?
  sum=$(printf '%s\n' "$out" |
    grep -m1 -E '^(SUMMARY: [A-Za-z]+Sanitizer|==[0-9]+==ERROR: [A-Za-z]+Sanitizer|.*runtime error:)' || true)
  if [ -n "$sum" ]; then printf 'CRASH\t%s\n' "$sum"; return 0; fi
  if [ "$rc" -eq 0 ]; then printf 'CLEAN\t-\n'; return 0; fi
  printf 'ERROR\texit=%s\n' "$rc"
}

# ensure_libs <srcdir> <sanitizer> -> prints the private build directory
#
# Copies the tree to /work/build-<fp>-<san>/src (never builds inside the source
# tree) and runs gpac's own configure/make, the way OSS-Fuzz does.
ensure_libs() {
  local dir=${1:?} s fp bld flags
  s=$(san_profile "${2:?}")
  [ -d "$dir" ] || die "no such source tree: $dir"
  [ -f "$dir/configure" ] || die "$dir/configure missing (it is tracked)"
  fp=$(src_fp "$dir"); bld="$WORK/build-$fp-$s"
  if [ -f "$bld/src/bin/gcc/libgpac_static.a" ]; then
    echo "cached  $bld" >&2; printf '%s\n' "$bld"; return 0
  fi

  flags="$(plain_flags) $(san_flags "$s")"
  rm -rf "$bld"; mkdir -p "$bld/src" "$OUT"
  ( cd "$dir" && tar -cf - --exclude=./.git . ) | ( cd "$bld/src" && tar -xf - ) ||
    die "cannot copy $dir"
  cd "$bld/src" || die "cannot enter $bld/src"

  echo "build   $dir [$s] -> $bld" >&2
  # Headless fuzz build.  Everything that would drag in a windowing or audio
  # backend is switched off: this image ships SDL 1.2 headers, pulse/alsa headers
  # and X11 stubs without the libraries behind them, and OSS-Fuzz's own image has
  # none of them, so the upstream fuzzer build is equally bare.
  #   --disable-x11 also drops sdl/directx (gpac's configure folds the three).
  ./configure --static-build --disable-x11 --disable-sdl --sdl-cfg=/nonexistent \
    --disable-pulseaudio --disable-alsa --disable-oss --disable-jack \
    --disable-directfb --disable-libcaca \
    --extra-cflags="$flags" --extra-ldflags="$flags" \
    > "$bld/configure.log" 2>&1 ||
    { tail -n 20 "$bld/configure.log" >&2; die "configure failed ($fp/$s)"; }
  # configure decides these by probing headers and then ignores --disable-<pkg>
  # for them (they are features, not packages, in its option parser).  This image
  # has the headers but not the libraries, so the objects would reference symbols
  # that cannot be linked.  OSS-Fuzz's own image has neither, and its configure
  # run ends with the same "no" here.
  for pkg in SDL X11 PULSEAUDIO ALSA JACK OSS DIRECTFB LIBCACA DVB4LINUX DIRECTX TINYGL VTB HID; do
    sed -i "s/^CONFIG_${pkg}=yes/CONFIG_${pkg}=no/" "$bld/src/config.mak"
  done
  make -j"${MAKE_JOBS:-4}" > "$bld/make.log" 2>&1 ||
    { grep -m5 -E 'error:|undefined reference' "$bld/make.log" >&2; tail -n 20 "$bld/make.log" >&2
      die "make failed ($fp/$s)"; }
  [ -f "$bld/src/bin/gcc/libgpac_static.a" ] || die "no libgpac_static.a after make ($fp/$s)"
  printf '%s\n' "$bld"
}

# ensure_libs_incr <patched_tree> <sanitizer> <patch> <baseline_tree>
#
# Same contract as ensure_libs, but instead of compiling gpac again it clones the
# baseline build directory for that sanitizer, applies the case's patch to the
# clone's source copy and lets make rebuild only the objects that changed.  A
# patch touches one to three files, so a case costs seconds instead of a full
# build.  The clone carries the same configure output, so the result is the same
# binary the cold path would produce -- verify-one.sh checks the verdict, and the
# cold path stays available (unset GPDT_PATCH) for a full rebuild.
ensure_libs_incr() {
  local dir=${1:?} s patch=${3:?} base_tree=${4:?} fp bld base
  s=$(san_profile "${2:?}")
  fp=$(src_fp "$dir"); bld="$WORK/build-$fp-$s"
  if [ -f "$bld/src/bin/gcc/libgpac_static.a" ]; then
    echo "cached  $bld" >&2; printf '%s\n' "$bld"; return 0
  fi
  base="$WORK/build-$(src_fp "$base_tree")-$s"
  if [ ! -f "$base/src/bin/gcc/libgpac_static.a" ]; then
    echo "no baseline build for $s, compiling $dir cold" >&2
    ensure_libs "$dir" "$s"; return
  fi
  rm -rf "$bld"
  cp -a "$base" "$bld" || die "cannot clone $base"
  ( cd "$bld/src" && patch -p1 -s -i "$patch" ) || die "patch $patch failed in $bld"
  echo "rebuild $bld [$s] (incremental)" >&2
  ( cd "$bld/src" && make -j"${MAKE_JOBS:-4}" >> "$bld/make.log" 2>&1 ) ||
    { grep -m5 -E 'error:|undefined reference' "$bld/make.log" >&2
      tail -n 20 "$bld/make.log" >&2; die "make failed ($fp/$s)"; }
  [ -f "$bld/src/bin/gcc/libgpac_static.a" ] || die "no libgpac_static.a after make ($fp/$s)"
  printf '%s\n' "$bld"
}

# ensure_repro <srcdir> <sanitizer> <target> -> prints /out/repro-<target>-<fp>-<san>
#
# Compiles the OSS-Fuzz fuzzer source (vendored from gpac/testsuite, pinned in
# README) against libgpac_static.a and links it with standalone_main.c, a driver
# that feeds one file to LLVMFuzzerTestOneInput once — no libFuzzer runtime.
ensure_repro() {
  local dir=${1:?} s tgt=${3:?} fp bld bin flags
  s=$(san_profile "${2:?}")
  fp=$(src_fp "$dir")
  if [ -n "${GPDT_PATCH:-}" ] && [ -n "${GPDT_INCR_BASE:-}" ]; then
    bld=$(ensure_libs_incr "$dir" "$s" "$GPDT_PATCH" "$GPDT_INCR_BASE") || exit 1
  else
    bld=$(ensure_libs "$dir" "$s") || exit 1
  fi
  bin="$OUT/repro-$tgt-$fp-$s"
  if [ -x "$bin" ]; then echo "cached  $bin" >&2; printf '%s\n' "$bin"; return 0; fi
  # Every enabled module records the library it needs in config.mak
  # (<pkg>_ldflags=); the OSS-Fuzz recipe hardcodes a short list because its
  # image has almost no optional libraries.  Backends this image cannot link
  # were switched off above, so their entries are empty and contribute nothing.
  MODLIBS=$(sed -n 's/^[a-z0-9_]*_ldflags=//p' "$bld/src/config.mak" | tr '\n' ' ')
  # The compositor's GL paths are compiled in (a static build keeps them) but
  # their link flags are not part of config.mak, so add them here.
  [ -f /usr/include/GL/gl.h ] && MODLIBS="$MODLIBS -lGL -lGLU"
  [ -f "$GPDT_HOME/$tgt.c" ] || die "no fuzzer source $tgt.c"
  flags="$(plain_flags) $(san_flags "$s")"

  echo "link    $bin" >&2
  ( cd "$bld/src" && \
    clang $flags -I./include -I./ -DGPAC_HAVE_CONFIG_H \
      -c "$GPDT_HOME/$tgt.c" -o "$bld/$tgt.o" && \
    clang $flags -c "$GPDT_HOME/standalone_main.c" -o "$bld/standalone_main.o" && \
    clang++ $flags "$bld/$tgt.o" "$bld/standalone_main.o" \
      ./bin/gcc/libgpac_static.a -lm -lz -lpthread $MODLIBS -o "$bin.new" ) ||
    die "reproducer build failed ($fp/$s)"
  mv -f "$bin.new" "$bin"

  # The instrumentation must really be in the binary.
  nm "$bin" > "$bld/nm.txt" 2>/dev/null || die "nm failed on $bin"
  case "$s" in
    address)   grep -q '__asan_' "$bld/nm.txt" || die "$bin is not ASan-instrumented" ;;
    undefined) grep -q '__ubsan_' "$bld/nm.txt" || die "$bin is not UBSan-instrumented" ;;
  esac
  echo "built   $bin ($(stat -c %s "$bin") bytes, $s)" >&2
  printf '%s\n' "$bin"
}
