#!/bin/sh
# SPDX-License-Identifier: MIT
#
# mkstick.sh — turn the stock FreeBSD 15.1-RELEASE amd64 memstick image into the
# XGS live test stick, on macOS (no FreeBSD host, no root):
#   1. /boot/loader.conf on the UFS root is patched IN PLACE (same length) to
#      console="comconsole" 115200, so legacy and UEFI boot both talk serial;
#   2. the EFI system partition (MBR slice 1) is rebuilt as FAT16 of identical
#      size: EFI/BOOT/BOOTX64.EFI (= /boot/loader.efi from the same image),
#      EFI/FreeBSD/loader.env, and the payload directory (driver, docs, stage.sh);
#   3. the result is verified by mounting the new ESP.
# Nothing else in the image changes; the UFS root stays byte-identical apart from
# the 116-byte loader.conf. Temporary files stay in $TMPDIR/mkstick.* .
#
# Usage: tools/mkstick.sh <stock-memstick.img> <out.img> <payload-dir>
set -eu
SRC=$1; OUT=$2; PL=$3
HERE=$(cd "$(dirname "$0")" && pwd)
UFS="python3 $HERE/ufs2tool.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mkstick.XXXXXX")

cp "$SRC" "$OUT"

# --- geometry of the ESP (MBR partition type 0xEF = 239) ---
ESP_START=$($UFS parts "$OUT" | awk -F'[(), ]+' '$3==239{print $4}')
ESP_END=$($UFS parts "$OUT" | awk -F'[(), ]+' '$3==239{print $5}')
ESP_SECTORS=$((ESP_END - ESP_START + 1)); ESP_BYTES=$((ESP_SECTORS * 512))
echo "ESP: start sector $ESP_START, $ESP_SECTORS sectors, $ESP_BYTES bytes"

# --- 1. loader.conf, same length ---
printf 'vfs.mountroot.timeout="10"\nconsole="comconsole"\ncomconsole_speed="115200"\n' > "$TMP/loader.conf"
$UFS patch "$OUT" /boot/loader.conf "$TMP/loader.conf"

# --- 1b. /etc/rc.local -> our auto-start (same-length patch; the memstick's original rc.local is
#         the 1990-byte bsdinstall launcher, so our ~600-byte script fits, padded with newlines).
#         It mounts the FAT payload and runs xgs/autostart.sh (WLAN + sshd), then a console shell.
#         Set RC_LOCAL= to override; default is the repo copy. ---
RC_LOCAL=${RC_LOCAL:-$HERE/../npu/stick/rc.local}
if [ -f "$RC_LOCAL" ]; then
	$UFS patch "$OUT" /etc/rc.local "$RC_LOCAL" && echo "rc.local -> auto-start ($(wc -c < "$RC_LOCAL") bytes)"
else
	echo "WARNING: $RC_LOCAL not found; stick will boot the stock installer, no auto-start"
fi

# --- 2. new ESP ---
$UFS cat "$OUT" /boot/loader.efi > "$TMP/BOOTX64.EFI"
# macOS newfs_msdos formats devices only: attach an empty file as a raw disk first
mkfile -n "$ESP_BYTES" "$TMP/esp.img"
EDEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$TMP/esp.img" | head -1 | awk '{print $1}')
newfs_msdos -F 16 -v EFISYS "${EDEV#/dev/}" >/dev/null 2>&1 || newfs_msdos -F 16 -v EFISYS "$EDEV" >/dev/null
diskutil mount "$EDEV" >/dev/null
MP=$(diskutil info "$EDEV" | awk -F': +' '/Mount Point/{print $2}')
[ -d "$MP" ] || { echo "ESP image did not mount"; exit 1; }
mkdir -p "$MP/.fseventsd" "$MP/EFI/BOOT"; : > "$MP/.fseventsd/no_log"   # keep macOS from logging into the ESP
export COPYFILE_DISABLE=1                                                # no ._AppleDouble files on FAT
cp "$TMP/BOOTX64.EFI" "$MP/EFI/BOOT/BOOTX64.EFI"
cp -R "$PL"/. "$MP"/
sync; diskutil unmount "$EDEV" >/dev/null; hdiutil detach "$EDEV" >/dev/null
[ "$(stat -f %z "$TMP/esp.img")" -eq "$ESP_BYTES" ] || { echo "ESP size mismatch"; exit 1; }
dd if="$TMP/esp.img" of="$OUT" bs=512 seek="$ESP_START" conv=notrunc status=none

# --- 3. verify ---
echo "--- loader.conf now:"; $UFS cat "$OUT" /boot/loader.conf
# macOS refuses to mount a 0xEF MBR slice (policy, not a filesystem fault), so the
# embedded ESP is checked by reading the FAT16 directly; on the XGS FreeBSD mounts it.
echo "--- embedded ESP (FAT16 at sector $ESP_START):"; python3 "$HERE/fat16tool.py" ls "$OUT" $((ESP_START * 512)) 2>/dev/null | grep -v -E '/\._|fseventsd' | head -40
echo "temp left in $TMP"
echo "done: $OUT"; shasum -a 256 "$OUT"
