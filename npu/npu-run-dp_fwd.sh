#!/bin/sh
# SPDX-License-Identifier: MIT
# npu-run-dp_fwd.sh -- runs ON the XGS NPU (CN9130, BusyBox sh, root). Swaps the Sophos
# data plane (usfp) for dp_fwd, volatile, from /tmp. Nothing on the NPU's storage is
# touched; a mains cycle restores the factory state (rootfs is read-only, /tmp is tmpfs).
#
#   npu-run-dp_fwd.sh status   what is loaded / running (safe, read-only)
#   npu-run-dp_fwd.sh start    stop usfp, load missing UIO modules, start dp_fwd from $DP
#   npu-run-dp_fwd.sh stop     stop dp_fwd (usfp is NOT restarted; mains cycle for factory)
#
# Expectations after `start`: the host's current AGNIC session is dead (usfp held it), so
# the host must reload if_agnic (kldunload/kldload) or warm-reboot. Stock NetAgent and
# UMSD_NPU keep running: switch config and NW_AGENT port discovery stay Sophos's.
# UNTESTED as of 2026-09-13: written from the measured NPU layout (usfp_startup_armada.sh,
# /usr/lib/modules/$(uname -r)/extra) and upstream's dp-autostart.sh; first run is the test.
DP=${DP:-/tmp/dp}
LOG=${LOG:-/tmp/dp_fwd.log}
READY='GIU pkt-echo is started'
ARGS='-g 2 -i eth0 -c 1 -a 1 -f dp-nmp-config.txt --no-stat'
MODDIR=/usr/lib/modules/$(uname -r)/extra
DEADLINE=${DEADLINE:-60}

have_mod() { grep -q "^$1 " /proc/modules 2>/dev/null; }
pids_of() { pidof "$1" 2>/dev/null || ps | awk -v n="$1" '$0 ~ n && $0 !~ /awk/ {print $1}' | tr '\n' ' '; }

status() {
	echo "kernel:   $(uname -r)"
	echo "modules:  $(for m in musdk_cma mv_dmax2_uio uio_pdrv_genirq mv_armada_ep mv_pcinet_trgt usfp_rh; do have_mod $m && printf '%s ' "$m"; done)"
	echo "devices:  $(ls /dev/uio* /dev/musdk-cma* 2>/dev/null | tr '\n' ' ')"
	echo "usfp:     $(pids_of usfp)"
	echo "dp_fwd:   $(pids_of dp_fwd)"
	echo "NetAgent: $(pids_of NetAgent)   UMSD_NPU: $(pids_of UMSD_NPU)"
	echo "staged:   $(ls -l "$DP" 2>/dev/null | tail -n +2 | awk '{print $5, $9}' | tr '\n' ';')"
	[ -f "$LOG" ] && { echo "log tail ($LOG):"; tail -5 "$LOG"; }
}

load_mods() {
	for m in musdk_cma mv_dmax2_uio uio_pdrv_genirq; do
		if have_mod "$m"; then echo "module $m: already loaded"; continue; fi
		extra=""; [ "$m" = uio_pdrv_genirq ] && extra="of_id=generic-uio"
		for ko in "$MODDIR/$m.ko" "$DP/modules/$m.ko"; do
			[ -f "$ko" ] || continue
			if insmod "$ko" $extra 2>/tmp/insmod.err; then echo "module $m: loaded from $ko"; break
			else echo "module $m: insmod $ko failed: $(cat /tmp/insmod.err)"; fi
		done
		have_mod "$m" || echo "WARNING: $m not loaded (dp_fwd will most likely fail to init)"
	done
}

stop_usfp() {
	# the wrapper first (else it may restart the child), then the DPDK process itself
	for n in usfp_startup_armada.sh usfp; do
		p=$(pids_of "$n"); [ -n "$p" ] || continue
		echo "stopping $n (pid $p)"; kill $p 2>/dev/null
	done
	i=0; while [ $i -lt 15 ] && [ -n "$(pids_of usfp)" ]; do sleep 1; i=$((i+1)); done
	p=$(pids_of usfp); [ -n "$p" ] && { echo "usfp still alive, SIGKILL"; kill -9 $p 2>/dev/null; sleep 2; }
	[ -z "$(pids_of usfp)" ] && echo "usfp stopped" || echo "WARNING: usfp still running"
}

start() {
	[ -x "$DP/dp_fwd" ] || { echo "no executable $DP/dp_fwd"; exit 1; }
	[ -f "$DP/dp-nmp-config.txt" ] || { echo "no $DP/dp-nmp-config.txt"; exit 1; }
	[ -n "$(pids_of dp_fwd)" ] && { echo "dp_fwd already running: $(pids_of dp_fwd)"; exit 1; }
	stop_usfp
	load_mods
	: >"$LOG"
	cd "$DP" || exit 1
	if command -v setsid >/dev/null 2>&1; then setsid sh -c "exec ./dp_fwd $ARGS" >>"$LOG" 2>&1 &
	else nohup ./dp_fwd $ARGS >>"$LOG" 2>&1 & fi
	echo "dp_fwd started, log $LOG, waiting up to ${DEADLINE}s for '$READY'"
	t=0
	while [ $t -lt "$DEADLINE" ]; do
		grep -q "$READY" "$LOG" 2>/dev/null && break
		[ -n "$(pids_of dp_fwd)" ] || { echo "dp_fwd EXITED before readiness:"; tail -20 "$LOG"; exit 2; }
		sleep 1; t=$((t+1))
	done
	sleep 2
	if grep -q "$READY" "$LOG" && [ -n "$(pids_of dp_fwd)" ]; then
		echo "READY after ${t}s, pid $(pids_of dp_fwd). Now reload if_agnic on the host."
	else
		echo "NOT READY after ${DEADLINE}s (alive: $(pids_of dp_fwd))"; tail -20 "$LOG"; exit 3
	fi
}

stop() {
	p=$(pids_of dp_fwd); [ -n "$p" ] || { echo "dp_fwd not running"; return; }
	kill $p; sleep 2; p=$(pids_of dp_fwd); [ -n "$p" ] && kill -9 $p
	echo "dp_fwd stopped. usfp is not restarted; a mains cycle restores the factory data plane."
}

case "${1:-status}" in
	status) status ;;
	start)  start ;;
	stop)   stop ;;
	*) echo "usage: $0 status|start|stop"; exit 64 ;;
esac
