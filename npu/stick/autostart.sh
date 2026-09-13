#!/bin/sh
# SPDX-License-Identifier: MIT
# autostart.sh -- runs from the stick's FAT payload at boot (via the patched /etc/rc.local).
# It does NOT start WLAN. It starts a key-only sshd that listens on ALL interfaces (every
# network port) on port 22, stages the NPU toolkit into /tmp, and then ESTABLISHES THE DATA
# PATH so the front ports carry traffic after a plain reboot (load if_agnic, start dp_fwd on
# the NPU, warm-reload the driver against it, DHCP port1). You then reach the box over that
# front port. WLAN is available only on demand: run  sh /tmp/wlan-up.sh  from the serial
# console. This is the host-side self-heal, not NPU persistence (a host reboot still resets
# the NPU to stock usfp; this re-establishes the working path each boot).
# Skip the data-path step with AUTO_DP=0 or a /mnt/xgs/no-autodp file.
ESP=/mnt/xgs
echo "=== autostart $(date 2>/dev/null || echo) ==="

# 1. key-only sshd on ALL interfaces, port 22 (host keys + authorized_keys in /tmp).
#    No ListenAddress -> sshd binds the wildcard (0.0.0.0 and ::), so it answers on whatever
#    front port / interface later gets an address. No WLAN is started here.
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
/usr/sbin/sshd -f /tmp/ssh/sshd_config && echo "sshd up (all interfaces, port 22)"

# 2. stage the NPU toolkit + driver + the MANUAL wlan script into /tmp
mkdir -p /tmp/dp
cp "$ESP"/dp_fwd "$ESP"/dp-nmp-config.txt "$ESP"/npu-run-dp_fwd.sh /tmp/dp/ 2>/dev/null
chmod +x /tmp/dp/dp_fwd /tmp/dp/npu-run-dp_fwd.sh 2>/dev/null
cp "$ESP"/mvmgt.x86 /tmp/mvmgt.x86 2>/dev/null; chmod 600 /tmp/mvmgt.x86 2>/dev/null
cp "$ESP"/if_agnic.ko /tmp/if_agnic.ko 2>/dev/null
cp "$ESP"/wlan-up.sh /tmp/wlan-up.sh 2>/dev/null; chmod +x /tmp/wlan-up.sh 2>/dev/null
echo "staged: /tmp/if_agnic.ko /tmp/dp/dp_fwd; WLAN on demand -> sh /tmp/wlan-up.sh"

# 3. establish the data path (front ports carry traffic). Skippable.
[ "${AUTO_DP:-1}" = "0" ] && { echo "AUTO_DP=0 -> skipping data-path bring-up"; exit 0; }
[ -f "$ESP/no-autodp" ] && { echo "/mnt/xgs/no-autodp present -> skipping data-path bring-up"; exit 0; }
[ -f /tmp/if_agnic.ko ] || { echo "if_agnic.ko missing -> cannot bring up data path"; exit 0; }

NPU_LL="fe80::7e5a:1cff:febc:48b%mvmgmt0"        # firmware constant, measured on the 116 and 126
DP_PORT="${DP_PORT:-port1}"                        # the front jack to DHCP (the home-LAN uplink)
KEY=/tmp/mvmgt.x86
NPUSSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR root@$NPU_LL"

npu_up() { ifconfig mvmgmt0 inet6 -ifdisabled auto_linklocal up 2>/dev/null; }
wait_npu() { k=0; while [ $k -lt 20 ]; do npu_up; ping6 -c1 -W2000 "$NPU_LL" >/dev/null 2>&1 && return 0; sleep 2; k=$((k+1)); done; return 1; }
dp_running() { [ -n "$($NPUSSH 'pidof dp_fwd' 2>/dev/null)" ]; }
wait_dp() { k=0; while [ $k -lt 40 ]; do dp_running && return 0; sleep 2; k=$((k+1)); done; return 1; }

echo "--- data path: loading if_agnic ---"
kldload /tmp/if_agnic.ko 2>/dev/null || kldstat | grep -q if_agnic || { echo "if_agnic load failed"; exit 0; }
k=0; while [ $k -lt 15 ] && ! ifconfig -l | grep -qw mvmgmt0; do sleep 1; k=$((k+1)); done

echo "--- data path: reaching the NPU over mvmgmt0 ---"
if ! wait_npu; then echo "NPU not reachable over mvmgmt0 -> data path not established (use serial console)"; exit 0; fi

# Does the NPU ALREADY run its own persistent dp_fwd (slot p2 / emmc2, via its
# /etc/init.d/S99dp-fwd -> /persistent/dp/dp-boot.sh)? If so we must NOT start a second
# one -- two dp_fwd crash the NPU -- we only bind it. Otherwise (stock NPU / slot p3) we
# stage and start dp_fwd from /tmp as before, so this stick works in both worlds.
if wait_dp; then
	echo "--- data path: NPU already runs persistent dp_fwd (pid $($NPUSSH 'pidof dp_fwd' 2>/dev/null)); binding it, NOT starting a second ---"
elif [ -x /tmp/dp/dp_fwd ]; then
	echo "--- data path: no dp_fwd on the NPU -> staging + starting it from /tmp (volatile) ---"
	$NPUSSH 'mkdir -p /tmp/dp' 2>/dev/null
	for f in dp_fwd dp-nmp-config.txt npu-run-dp_fwd.sh; do $NPUSSH "cat > /tmp/dp/$f" < "/tmp/dp/$f" 2>/dev/null; done
	$NPUSSH 'chmod +x /tmp/dp/dp_fwd /tmp/dp/npu-run-dp_fwd.sh; sh /tmp/dp/npu-run-dp_fwd.sh start' 2>&1 | tail -3
else
	echo "--- data path: no persistent dp_fwd and no /tmp/dp/dp_fwd -> nothing to bind (stock NPU forwards nothing) ---"
fi

echo "--- data path: one clean warm-reload of if_agnic to bind dp_fwd ---"
kldunload if_agnic 2>/dev/null; sleep 2; kldload /tmp/if_agnic.ko 2>/dev/null
sleep 8
npu_up

echo "--- data path: DHCP on $DP_PORT ---"
if ifconfig "$DP_PORT" >/dev/null 2>&1; then
	timeout 30 dhclient "$DP_PORT" 2>&1 | grep -E 'DHCPACK|bound' || echo "dhclient $DP_PORT: no lease (cable? DHCP server?)"
	echo "$DP_PORT: $(ifconfig "$DP_PORT" 2>/dev/null | awk '/inet /{print $2; exit}')  <- ssh here"
else
	echo "$DP_PORT does not exist after reload"
fi
echo "=== autostart done; front ports live (giu_rx=$(sysctl -n dev.agnic.0.npu_giu_rx 2>/dev/null) pp2_tx=$(sysctl -n dev.agnic.0.npu_pp2_tx 2>/dev/null)) ==="
