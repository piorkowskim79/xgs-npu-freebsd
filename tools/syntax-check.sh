#!/bin/sh
# SPDX-License-Identifier: MIT
#
# syntax-check.sh — type-check the if_agnic sources against a FreeBSD sys/ tree
# with `clang -fsyntax-only`, on any host that has clang (macOS, Linux, FreeBSD).
#
# This is NOT a build. It catches API drift (if_t, bus_dma, sysctl, mbuf) and
# plain C errors without a FreeBSD build host. The real build is `make` in
# driver/ on a FreeBSD host with /usr/src (see docs/TESTBED.md).
#
# Usage:
#   FREEBSD_SYS=/path/to/freebsd-src/sys tools/syntax-check.sh [driver-dir]
#
# A sparse checkout is enough:
#   git clone --depth 1 --filter=blob:none --sparse -b releng/15.1 \
#       https://github.com/freebsd/freebsd-src.git fbsd15
#   (cd fbsd15 && git sparse-checkout set sys/sys sys/amd64/include \
#       sys/x86/include sys/net sys/netinet sys/netinet6 sys/dev/pci sys/kern \
#       sys/vm sys/contrib/ck/include sys/tools sys/conf)
#   FREEBSD_SYS=$PWD/fbsd15/sys tools/syntax-check.sh
set -eu

SYS=${FREEBSD_SYS:?set FREEBSD_SYS=/path/to/freebsd-src/sys}
HERE=$(cd "$(dirname "$0")" && pwd)
DRV=${1:-$HERE/../driver}
DRV=$(cd "$DRV" && pwd)
CC=${CC:-clang}
TARGET=${TARGET:-x86_64-unknown-freebsd15.1}
OBJ=${OBJDIR:-$(mktemp -d "${TMPDIR:-/tmp}/agnic-syntax.XXXXXX")}

mkdir -p "$OBJ"
cd "$OBJ"

# newbus interface headers (what bsd.kmod.mk generates from the .m files)
for m in kern/device_if kern/bus_if dev/pci/pci_if; do
	awk -f "$SYS/tools/makeobjops.awk" "$SYS/$m.m" -h
done

# machine/ and x86/ are symlinks in a real kernel objdir
ln -sfn "$SYS/amd64/include" "$OBJ/machine"
ln -sfn "$SYS/x86/include" "$OBJ/x86"

# kernel option headers: an out-of-tree kmod build sees them empty
for o in global inet inet6 bus ddb kdb ktr hwpmc_hooks sched vm kstack_pages \
    lock_profile printf compat capsicum stack sysctl acpi pci iommu kern_tls \
    ratelimit rss netgraph bpf vlan_var altq sctp ipsec ipfw route mrouting \
    param mac posix random watchdog zstdio geom; do
	: > "$OBJ/opt_$o.h"
done

CFLAGS="-target $TARGET -fsyntax-only -nostdinc \
 -D_KERNEL -DKLD_MODULE -DHAVE_KERNEL_OPTION_HEADERS -include $OBJ/opt_global.h \
 -I$OBJ -I$DRV -I$SYS -I$SYS/contrib/ck/include \
 -std=gnu99 -ffreestanding -fno-builtin -fno-common -fwrapv \
 -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -msoft-float -mno-aes -mno-avx \
 -Wall -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith -Wcast-qual \
 -Wundef -Wno-pointer-sign -Wmissing-include-dirs -Wno-unknown-pragmas \
 -Wno-address-of-packed-member -Wredundant-decls -Wnested-externs \
 -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
 -Wno-format-invalid-specifier -Wno-format-extra-args"
# The two -Wno-format-* above: FreeBSD's kernel printf has the %D (hexdump), %b
# and %r extensions, which FreeBSD's own clang validates via __printflike but a
# stock clang reports as an invalid specifier. Not a defect in the driver.

rc=0
for c in "$DRV"/*.c; do
	printf '%-20s ' "$(basename "$c")"
	if $CC $CFLAGS "$c" 2> "$OBJ/err.txt"; then
		if [ -s "$OBJ/err.txt" ]; then
			echo "ok (with warnings)"; cat "$OBJ/err.txt"
		else
			echo "ok"
		fi
	else
		echo "FAIL"
		cat "$OBJ/err.txt"
		rc=1
	fi
done
[ "$rc" -eq 0 ] && echo "syntax-check: all sources pass against $SYS ($TARGET)"
exit $rc
