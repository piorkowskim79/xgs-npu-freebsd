#!/bin/sh
# SPDX-License-Identifier: MIT
# build-dp_fwd-on-pi.sh -- native aarch64 build of the NPU data plane (dp_fwd) on a
# Raspberry Pi 5 / Debian 13, fully static, reproducible from pinned revisions.
#
# dp_fwd is upstream's forwarder (mamoru-xgs-npu/npu-firmware/forwarder/forwarder.c,
# Marvell code under the GPLv2 election) built inside Marvell's MUSDK tree in place of
# the giu/pkt_echo example, exactly as upstream's build/build_fwd.sh does. Upstream
# cross-builds on x86 with the Bootlin 2018.11 toolchain (glibc 2.27, the NPU's) and
# links dynamically. Here the build host is the same architecture as the NPU, so the
# distro compiler is used natively; because the Pi's glibc (2.41) is far newer than the
# NPU's, the result is linked fully static (libtool: -all-static) and depends on nothing
# on the NPU but the kernel (4.14; GNU/Linux ABI floor 3.7 as stamped in the ELF).
#
# Differences from upstream's pipeline, all deliberate:
#   - native gcc 14 instead of GCC 7.3: MUSDK's configure.ac adds -Werror; new warnings
#     in 2018-era code would abort the build, so that one line is commented out here.
#   - GCC 14 turns a few old-C sloppinesses into errors; they are downgraded back to
#     warnings with -Wno-error=... so the tree compiles unmodified.
#   - LDFLAGS=-all-static at make time (not at configure time: configure's link probe
#     runs plain gcc, which does not know libtool's -all-static).
#
# Usage (on the Pi):  sh build-dp_fwd-on-pi.sh
#   env: BUILD_ROOT (default ~/npu-build), JOBS (default nproc), KIT_REV, MUSDK_REV
# Output: $BUILD_ROOT/out/ -- dp_fwd (stripped), dp_fwd.debug, dp-nmp-config.txt,
#   npu-run-dp_fwd.sh, BUILD-INFO.txt, SHA256SUMS, upstream-xgs116-payload/ (fallback).
# The script never deletes anything outside the MUSDK checkout (git clean) on purpose.
set -eu

BUILD_ROOT=${BUILD_ROOT:-$HOME/npu-build}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
KIT_URL=https://github.com/samuelleb11/mamoru-xgs-npu.git
KIT_REV=${KIT_REV:-e4101698b32350e3e2cc8ae09ae98e9c78e2170e}      # 2026-09-07
MUSDK_URL=https://github.com/MarvellEmbeddedProcessors/musdk-marvell.git
MUSDK_BRANCH=musdk-release-SDK-10.3.5.0-PR2                          # what upstream's env.sh pins
MUSDK_REV=${MUSDK_REV:-278748af6e197672551ba220c8720d9ae0a8461e}    # tip of that branch, 2020-12-16
KIT=$BUILD_ROOT/mamoru-xgs-npu
MUSDK=$BUILD_ROOT/musdk
OUT=$BUILD_ROOT/out
HERE=$(cd "$(dirname "$0")" && pwd)

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---- 0. host checks ------------------------------------------------------------------
[ "$(uname -m)" = aarch64 ] || die "this script builds natively and needs an aarch64 host (got $(uname -m))"
missing=""
for t in gcc make git autoconf automake libtoolize m4 file strip nm readelf; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	say "installing missing build tools:$missing"
	sudo -n true 2>/dev/null || die "need: sudo apt-get install -y build-essential git autoconf automake libtool m4 file binutils"
	sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
		build-essential git autoconf automake libtool m4 file binutils >/dev/null
fi
mkdir -p "$BUILD_ROOT" "$OUT"

# ---- 1. sources at pinned revisions --------------------------------------------------
say "kit: $KIT_URL @ $KIT_REV"
if [ ! -d "$KIT/.git" ]; then git clone -q "$KIT_URL" "$KIT"; fi
git -C "$KIT" fetch -q origin
git -C "$KIT" checkout -q -f "$KIT_REV"
[ "$(git -C "$KIT" rev-parse HEAD)" = "$KIT_REV" ] || die "kit checkout did not land on $KIT_REV"

say "musdk: $MUSDK_URL branch $MUSDK_BRANCH @ $MUSDK_REV"
if [ ! -d "$MUSDK/.git" ]; then git clone -q "$MUSDK_URL" "$MUSDK"; fi
git -C "$MUSDK" fetch -q origin "$MUSDK_BRANCH"
git -C "$MUSDK" checkout -q -f "$MUSDK_REV"
[ "$(git -C "$MUSDK" rev-parse HEAD)" = "$MUSDK_REV" ] || die "musdk checkout did not land on $MUSDK_REV"
git -C "$MUSDK" clean -fdxq          # always from clean: reproducibility over speed (~25 s on a Pi 5)

# ---- 2. adapt MUSDK for a native gcc-14 build -----------------------------------------
say "neutralising -Werror in configure.ac"
n=$(grep -c '^CFLAGS+="-Werror "' "$MUSDK/configure.ac" || true)
[ "$n" = 1 ] || die "expected exactly one -Werror line in configure.ac, found $n (MUSDK revision changed?)"
sed -i 's/^CFLAGS+="-Werror "/# native gcc-14 build (xgs-npu-freebsd): CFLAGS+="-Werror "/' "$MUSDK/configure.ac"

# ---- 3. drop the forwarder into the pkt_echo slot (upstream build_fwd.sh, verbatim) ----
say "installing forwarder.c + wire-contract headers into the MUSDK tree"
PE=$MUSDK/apps/examples/giu/pkt_echo
cp "$KIT/npu-firmware/forwarder/forwarder.c" "$PE/pkt_echo.c"
for h in tag_dsa.h pport_hdr.h portmap.h dp_config.h dp_swop.h dp_swop.c dp_sff.h dp_sff.c; do
	cp "$KIT/npu-firmware/src/$h" "$MUSDK/apps/include/"
done

# ---- 4. bootstrap / configure / make ---------------------------------------------------
# MUSDK's mvapp.c/cli.c stamp __DATE__/__TIME__ into the binary; gcc takes both from
# SOURCE_DATE_EPOCH, so pinning it to the kit's commit time makes the build bit-for-bit
# reproducible (verified: two consecutive runs, identical sha256).
SOURCE_DATE_EPOCH=$(git -C "$KIT" log -1 --format=%ct); export SOURCE_DATE_EPOCH
cd "$MUSDK"
say "bootstrap"
./bootstrap >"$BUILD_ROOT/log-bootstrap.txt" 2>&1 || { tail -20 "$BUILD_ROOT/log-bootstrap.txt"; die "bootstrap failed"; }
say "configure (pp2 + giu + nmp, 64-bit DMA addresses, uio-cma, static lib)"
./configure --enable-static --disable-shared --enable-dma-addr=64 \
	--enable-pp2 --enable-giu --enable-nmp --enable-sam=no --enable-neta=no \
	CFLAGS="-O2 -g -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" \
	>"$BUILD_ROOT/log-configure.txt" 2>&1 || { tail -30 "$BUILD_ROOT/log-configure.txt"; die "configure failed"; }
grep -q -- '-DMVCONF_DMA_PHYS_ADDR_T_SIZE=64' Makefile || die "configure did not select 64-bit DMA addresses"
say "make -j$JOBS LDFLAGS=-all-static"
make -j"$JOBS" LDFLAGS="-all-static" >"$BUILD_ROOT/log-make.txt" 2>&1 || { grep -E 'error' "$BUILD_ROOT/log-make.txt" | head -30; die "make failed (full log: $BUILD_ROOT/log-make.txt)"; }

# ---- 5. verify and publish -------------------------------------------------------------
BIN=$(find "$MUSDK" -name musdk_giu_pkt_echo -type f | head -1)
[ -n "$BIN" ] || die "no musdk_giu_pkt_echo produced"
file "$BIN" | grep -q 'ARM aarch64'       || die "not an aarch64 binary: $(file "$BIN")"
file "$BIN" | grep -q 'statically linked' || die "not statically linked: $(file "$BIN")"
readelf -l "$BIN" | grep -q INTERP && die "binary still has a PT_INTERP (dynamic loader) entry"
nm "$BIN" | grep -q ' T dp_sff_'          || die "dp_sff symbols missing: this is the stock pkt_echo, not the forwarder"
strings "$BIN" | grep -q 'swop capability' || die "forwarder marker string missing"

cp "$BIN" "$OUT/dp_fwd.debug"
strip -o "$OUT/dp_fwd" "$BIN"
cp "$KIT/npu-firmware/deploy/dp-nmp-config.txt" "$OUT/"
for f in npu-run-dp_fwd.sh xgs-fetch-and-relay.sh; do [ -f "$HERE/$f" ] && cp "$HERE/$f" "$OUT/"; done
{
	echo "built:      $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname) ($(uname -srm))"
	echo "compiler:   gcc $(gcc -dumpfullversion), glibc $(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$') (static, not a runtime dependency)"
	echo "kit:        $KIT_URL @ $KIT_REV"
	echo "musdk:      $MUSDK_URL $MUSDK_BRANCH @ $MUSDK_REV"
	echo "configure:  --enable-static --disable-shared --enable-dma-addr=64 --enable-pp2 --enable-giu --enable-nmp --enable-sam=no --enable-neta=no"
	echo "cflags:     $(grep -E '^CFLAGS =' "$MUSDK/Makefile" | sed 's/^CFLAGS = //')"
	echo "ldflags:    -all-static (make time)"
	echo "epoch:      SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (kit commit time; fixes __DATE__/__TIME__)"
	echo "target abi: $(file "$OUT/dp_fwd" | grep -oE 'for GNU/Linux [0-9.]+')"
	echo "run as:     ./dp_fwd -g 2 -i eth0 -c 1 -a 1 -f dp-nmp-config.txt --no-stat   (cwd = directory holding the config)"
	echo "ready mark: 'GIU pkt-echo is started' on stdout"
} >"$OUT/BUILD-INFO.txt"

# ---- 6. upstream's prebuilt XGS 116 payload as a fallback ------------------------------
say "extracting upstream's XGS 116 payload (prebuilt dp_fwd + the three UIO modules) as fallback"
PAY=$KIT/npu-firmware/deploy/payload
UP=$OUT/upstream-xgs116-payload
mkdir -p "$UP"
( cd "$PAY" && while read -r name bytes sha _; do
	case "$name" in \#*|"") continue ;; esac
	[ "$(wc -c <"$name")" = "$bytes" ] || die "payload size mismatch: $name"
	echo "$sha  $name" | sha256sum -c --quiet - || die "payload sha256 mismatch: $name"
  done <MANIFEST )
tar -C "$UP" --strip-components=3 -xf "$PAY/rootfs-dp.tar" ./opt/dp 2>/dev/null
tar -C "$UP" --strip-components=3 -xf "$PAY/rootfs-dp.tar" ./etc/init.d/rcS 2>/dev/null && mv -f "$UP/rcS" "$UP/rcS-upstream"

cd "$OUT" && sha256sum dp_fwd dp_fwd.debug dp-nmp-config.txt upstream-xgs116-payload/dp_fwd upstream-xgs116-payload/modules/*.ko >SHA256SUMS
say "done: $OUT"
ls -l "$OUT"
cat "$OUT/BUILD-INFO.txt"
echo; echo "sha256 dp_fwd (stripped): $(sha256sum "$OUT/dp_fwd" | cut -c1-64)"
echo "BUILD_DP_FWD_DONE"
