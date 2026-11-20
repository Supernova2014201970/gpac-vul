# gpac-vul — reproduction environment.
#
# Build (context = the gpac-vul/ directory):
#   docker build -f image/Dockerfile -t gpac-vul:b890f1c .
#
# The base is the OSS-Fuzz builder image the sibling ffmpeg dataset already uses:
# Ubuntu 16.04 with clang 5.0.0, the ASan/UBSan runtimes and zlib development
# headers — everything gpac's configure asks for.  Its own project sources and
# reproducers are removed below so exactly one tree remains.  (The imagemagick
# image was tried first; it is the same era but ships no zlib headers, and gpac's
# configure refuses to run without them.)
#
# The delivered tree is upstream
#
#   b890f1c443dbe1f941cd326d4473ce7ddef8e256   2024-01-17
#   ("fixed potential crash in rtp input init", the commit before the fix window)
#
# copied from src/gpac-readonly, a plain checkout without .git — the same bytes
# the shipped snapshot holds.  Nothing is patched into it: the per-case fixes
# live in /payload/patches and are applied to a copy at verify time.
#
#   /src/gpac   the baseline checkout (no .git)
#   /payload    cases.tsv, 27 PoCs, 27 patches, patch-index.json, vulnerabilities.json
#   /opt/gpdt   lib.sh, build.sh, verify.sh, verify-one.sh, verify-one-by-one.sh,
#               fuzz_probe_analyze.c, fuzz_parse.c, standalone_main.c
#   /out        repro-<target>-<fp>-<san>: the ASan and UBSan baseline reproducers
#   /work       empty — verify runs build there
FROM n132/arvo@sha256:95cd4fadae89976811235d6b70b4d750c42a380845f7df27dc644333fef05052

SHELL ["/bin/bash", "-c"]

RUN rm -rf /src/* /out/* /work/*
COPY src/gpac-readonly/ /src/gpac/
COPY payload/ /payload/
COPY scripts/ /opt/gpdt/

WORKDIR /opt/gpdt

# Two gates before anything is built: the tree must hash to the snapshot the
# payload was generated from, and every shipped patch must apply to it.
RUN set -eux; \
    chmod +x /opt/gpdt/*.sh; \
    cd /src/gpac; \
    test "$(find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)" = 3fb52327008566a2; \
    for p in /payload/patches/*.patch; do patch -p1 --dry-run -s -i "$p"; done; \
    test "$(awk -F'\t' '!/^#/ && NF >= 8' /payload/cases.tsv | wc -l)" = 27; \
    test "$(ls -d /payload/pocs/*/poc | wc -l)" = 27

ENV SRC=/src/gpac \
    PAYLOAD=/payload \
    OUT=/out \
    WORK=/work \
    GPDT_TREE=/src/gpac \
    PATH=/opt/gpdt:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build both instrumented baselines and run every PoC: on this tree each one must
# still crash, so a silent change in the baseline, a PoC or the table fails the
# build instead of turning up later in a report.  Writes /reports/verify.json and
# leaves /out warm; /work is emptied again so verify-one.sh does real builds.
RUN set -eux; \
    verify.sh --report /reports; \
    rm -rf /work/*

# The delivered layout, asserted.
RUN set -eux; \
    test "$(ls /src)" = gpac; \
    test ! -e /src/gpac/.git; \
    test -f /src/gpac/configure; \
    test -f /src/gpac/src/media_tools/av_parsers.c; \
    test "$(ls /payload/patches/*.patch | wc -l)" = 27; \
    test "$(ls -d /payload/pocs/*/poc | wc -l)" = 27; \
    test "$(ls /out | wc -l)" = 3; \
    test -z "$(ls -A /work)"

CMD ["/bin/bash"]
