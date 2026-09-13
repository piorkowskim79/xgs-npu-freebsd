#!/bin/sh
# SPDX-License-Identifier: MIT
# xgs-ssh.sh -- start sshd on the read-only FreeBSD live stick, key-only root login,
# host keys and authorized_keys in /tmp (nothing on the stick is written).
#   fetch -o /tmp/xgs-ssh.sh http://<build-host>:8000/xgs-ssh.sh && sh /tmp/xgs-ssh.sh http://<build-host>:8000
# The build host serves authorized_keys next to this script (see docs/NPU-BUILD.md).
set -eu
SRC=${1:-http://192.168.2.187:8000}
D=/tmp/ssh
mkdir -p "$D"; chmod 700 "$D"
[ -s "$D/authorized_keys" ] || fetch -q -o "$D/authorized_keys" "$SRC/authorized_keys"
chmod 600 "$D/authorized_keys"
for t in ed25519 rsa; do [ -f "$D/host_$t" ] || ssh-keygen -q -t "$t" -N '' -f "$D/host_$t"; done
cat >"$D/sshd_config" <<CFG
Port 22
HostKey $D/host_ed25519
HostKey $D/host_rsa
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $D/authorized_keys
PidFile $D/sshd.pid
UseDNS no
Subsystem sftp /usr/libexec/sftp-server
CFG
[ -f "$D/sshd.pid" ] && pkill -F "$D/sshd.pid" 2>/dev/null || true
/usr/sbin/sshd -f "$D/sshd_config"
echo "sshd listening; log in as root with the key from authorized_keys at:"
ifconfig -a | awk '/inet / && $2 != "127.0.0.1" {print "  ssh root@" $2}'
