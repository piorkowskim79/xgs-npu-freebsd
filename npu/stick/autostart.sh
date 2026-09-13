#!/bin/sh
# SPDX-License-Identifier: MIT
# autostart.sh -- runs from the stick's FAT payload at boot (via the patched /etc/rc.local).
# Brings up the USB WLAN from wpa.conf, then a key-only sshd, all in /tmp (root is read-only),
# and stages the NPU toolkit into /tmp/dp. No console typing, no pasting. UNTESTED until first boot.
ESP=/mnt/xgs
echo "=== autostart $(date 2>/dev/null || echo) ==="

# 1. wait for the RTL8188CUS radio to settle -- it flaps on USB enumerate
i=0; while [ $i -lt 30 ]; do
	sysctl -n net.wlan.devices 2>/dev/null | grep -qw rtwn0 && break
	sleep 1; i=$((i+1))
done
sysctl -n net.wlan.devices 2>/dev/null | grep -qw rtwn0 || { echo "no rtwn0 after 30s"; }

# 2. WLAN join, retried (the adapter drops link on enumerate)
ifconfig wlan0 >/dev/null 2>&1 || ifconfig wlan0 create wlandev rtwn0
ifconfig wlan0 up
n=0
while [ $n -lt 6 ]; do
	pkill wpa_supplicant 2>/dev/null
	wpa_supplicant -B -i wlan0 -c "$ESP/wpa.conf" 2>/dev/null
	j=0; while [ $j -lt 20 ]; do ifconfig wlan0 2>/dev/null | grep -q 'status: associated' && break; sleep 1; j=$((j+1)); done
	if ifconfig wlan0 2>/dev/null | grep -q 'status: associated'; then
		dhclient wlan0 2>/dev/null && ifconfig wlan0 | grep -q 'inet ' && break
	fi
	n=$((n+1)); sleep 3
done
echo "wlan0: $(ifconfig wlan0 2>/dev/null | awk '/status:|inet /{print}' | tr '\n' ' ')"

# 3. key-only sshd, host keys + authorized_keys in /tmp
mkdir -p /tmp/ssh; chmod 700 /tmp/ssh
cp "$ESP/authorized_keys" /tmp/ssh/authorized_keys 2>/dev/null; chmod 600 /tmp/ssh/authorized_keys 2>/dev/null
for t in ed25519 rsa; do [ -f /tmp/ssh/host_$t ] || ssh-keygen -q -t $t -N '' -f /tmp/ssh/host_$t; done
cat > /tmp/ssh/sshd_config <<CFG
Port 22
HostKey /tmp/ssh/host_ed25519
HostKey /tmp/ssh/host_rsa
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile /tmp/ssh/authorized_keys
PidFile /tmp/ssh/sshd.pid
StrictModes no
UseDNS no
CFG
/usr/sbin/sshd -f /tmp/ssh/sshd_config && echo "sshd up"

# 4. stage the NPU toolkit + driver so I can work immediately over SSH
mkdir -p /tmp/dp
cp "$ESP"/dp_fwd "$ESP"/dp-nmp-config.txt "$ESP"/npu-run-dp_fwd.sh /tmp/dp/ 2>/dev/null
chmod +x /tmp/dp/dp_fwd /tmp/dp/npu-run-dp_fwd.sh 2>/dev/null
cp "$ESP"/mvmgt.x86 /tmp/mvmgt.x86 2>/dev/null; chmod 600 /tmp/mvmgt.x86 2>/dev/null
cp "$ESP"/if_agnic.ko /tmp/if_agnic.ko 2>/dev/null
echo "=== autostart done; ssh root@$(ifconfig wlan0 2>/dev/null | awk '/inet /{print $2; exit}') ==="
