#!/bin/sh
# SPDX-License-Identifier: MIT
# wlan-up.sh -- MANUAL WLAN join for the XGS live stick. The stick does NOT bring WLAN up on
# its own; run this from the serial console when you need it:  sh /tmp/wlan-up.sh
# It uses the wpa.conf already on the stick's FAT payload (edit SSID/PSK there, or pass a file:
#   sh /tmp/wlan-up.sh /path/to/wpa.conf ). The RTL8188CUS is 2.4 GHz only and flaps on
# enumerate, so the join is retried.
set -u
WPA=${1:-}
for c in "$WPA" /mnt/xgs/wpa.conf /tmp/wpa.conf; do [ -n "$c" ] && [ -f "$c" ] && { WPA=$c; break; }; done
[ -n "${WPA:-}" ] && [ -f "$WPA" ] || { echo "no wpa.conf found (looked at /mnt/xgs/wpa.conf); pass one as arg 1"; exit 1; }
echo "wlan-up: using $WPA"

# wait for the radio, then join (retried)
i=0; while [ $i -lt 15 ]; do sysctl -n net.wlan.devices 2>/dev/null | grep -qw rtwn0 && break; sleep 1; i=$((i+1)); done
sysctl -n net.wlan.devices 2>/dev/null | grep -qw rtwn0 || echo "warning: rtwn0 not present; is the USB WLAN plugged in?"
ifconfig wlan0 >/dev/null 2>&1 || ifconfig wlan0 create wlandev rtwn0
ifconfig wlan0 up
n=0
while [ $n -lt 8 ]; do
	pkill wpa_supplicant 2>/dev/null
	wpa_supplicant -B -i wlan0 -c "$WPA" 2>/dev/null
	j=0; while [ $j -lt 20 ]; do ifconfig wlan0 2>/dev/null | grep -q 'status: associated' && break; sleep 1; j=$((j+1)); done
	if ifconfig wlan0 2>/dev/null | grep -q 'status: associated'; then
		dhclient wlan0 2>/dev/null && ifconfig wlan0 | grep -q 'inet ' && break
	fi
	n=$((n+1)); sleep 3
done
IP=$(ifconfig wlan0 2>/dev/null | awk '/inet /{print $2; exit}')
if [ -n "$IP" ]; then echo "wlan0 up: $IP  (ssh root@$IP)"; else echo "wlan0 did NOT come up; check SSID/PSK in $WPA and the adapter"; fi
