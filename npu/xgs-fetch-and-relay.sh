#!/bin/sh
# SPDX-License-Identifier: MIT
# xgs-fetch-and-relay.sh -- runs on the XGS HOST (FreeBSD live stick, root). Pulls the
# staged NPU files from the build host over the USB NIC and relays them to the NPU's
# /tmp over mvmgmt0. Needs: if_agnic loaded with mvmgmt0 established, the Sophos NPU
# key at $KEY (see docs/XGS126.md), and `python3 -m http.server 8000` running in
# ~/npu-build/out on the build host.
#
#   xgs-fetch-and-relay.sh http://<build-host>:8000
#
# Files are streamed through ssh (cat), not scp, so the NPU needs no scp binary.
# UNTESTED as of 2026-09-13.
set -eu
SRC=${1:?usage: $0 http://<build-host>:8000}
NPU=${NPU_LL:-fe80::7e5a:1cff:febc:48b%mvmgmt0}     # measured on the XGS 126 (and both 116s)
KEY=${NPU_KEY:-/tmp/mvmgt.x86}
LOCAL=${LOCAL:-/tmp/dp}
FILES="dp_fwd dp-nmp-config.txt npu-run-dp_fwd.sh SHA256SUMS"
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@$NPU"

[ -r "$KEY" ] || { echo "NPU key $KEY missing"; exit 1; }
mkdir -p "$LOCAL"; cd "$LOCAL"
for f in $FILES; do fetch -q -o "$f" "$SRC/$f"; done
sha256sum -c --ignore-missing SHA256SUMS 2>/dev/null || sha256 -c "$(awk '$2=="dp_fwd"{print $1}' SHA256SUMS)" dp_fwd
echo "fetched into $LOCAL:"; ls -l

$SSH 'mkdir -p /tmp/dp'
for f in $FILES; do $SSH "cat > /tmp/dp/$f" <"$f"; done
$SSH 'chmod +x /tmp/dp/dp_fwd /tmp/dp/npu-run-dp_fwd.sh; cd /tmp/dp && sha256sum dp_fwd dp-nmp-config.txt && sh npu-run-dp_fwd.sh status'
echo
echo "next, on the NPU:  ssh -i $KEY root@$NPU 'sh /tmp/dp/npu-run-dp_fwd.sh start'"
echo "then on this host: kldunload if_agnic && kldload /path/to/if_agnic.ko   (or warm reboot)"
