#!/bin/sh
# SPDX-License-Identifier: MIT
# xgs-wlan.sh -- join a WPA2 network from the FreeBSD live stick through a USB WLAN
# adapter (rtwn/run/otus/urtw). Everything lives in /tmp: the stick's root is read-only.
# Paste it at the serial console (the stick cannot fetch it before it has a network):
#   sh /tmp/xgs-wlan.sh [rtwn0]
# It asks for SSID and passphrase; the passphrase is not echoed and stays in /tmp/wlan.
set -eu
DEV=${1:-rtwn0}
# the radio is not an interface (that is wlan0, created below); it is listed by net80211
sysctl -n net.wlan.devices 2>/dev/null | grep -qw "$DEV" || { echo "no $DEV in net.wlan.devices (dmesg | tail: is the adapter attached and stable?)"; exit 1; }
printf 'SSID: '; read -r SSID
printf 'Passphrase: '; stty -echo; read -r PSK; stty echo; echo
mkdir -p /tmp/wlan; chmod 700 /tmp/wlan
printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$SSID" "$PSK" >/tmp/wlan/wpa.conf
chmod 600 /tmp/wlan/wpa.conf
ifconfig wlan0 >/dev/null 2>&1 || ifconfig wlan0 create wlandev "$DEV"
ifconfig wlan0 up
pkill wpa_supplicant 2>/dev/null || true
wpa_supplicant -B -i wlan0 -c /tmp/wlan/wpa.conf -P /tmp/wlan/wpa.pid
i=0; while [ $i -lt 20 ]; do ifconfig wlan0 | grep -q 'status: associated' && break; sleep 1; i=$((i+1)); done
ifconfig wlan0 | grep -E 'ssid|status'
ifconfig wlan0 | grep -q 'status: associated' || { echo "not associated after ${i}s; ifconfig wlan0 list scan to see what the adapter hears"; exit 2; }
dhclient wlan0
ifconfig wlan0 | grep 'inet '
