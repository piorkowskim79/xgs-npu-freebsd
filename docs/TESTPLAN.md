# Test plan: staged bring-up on the XGS 126

Every stage names the tunables to set, the log lines that mean "pass", and what to
record. Do not skip stages: the NPU keeps state across host reboots (it latches the
mgmt ring addresses once per NPU boot), and a stage that went wrong can only be undone
with a mains cycle of the whole box. All waits in the driver are bounded, so a stage
that fails logs a timeout and leaves the box reachable over the USB NIC.

Log target: `dmesg`, plus `sysctl dev.agnic.0` and `sysctl hw.agnic` after each stage.

## Stage 0: attach only (no NPU handshake)

```sh
kenv hw.agnic.mgmt=0
kldload ./if_agnic.ko
```

Pass:

```
agnic0: <Marvell AGNIC GIU-NIC (Sophos XGS NPU, PF)> ... at device 0.0 on pci1
agnic0: platform: <product> <version> (hw.agnic: mgmt=0 ...)
agnic0: BAR0: pa 0x... size 1024 KiB
agnic0: BAR2: pa 0x... size 16384 KiB
agnic0: BAR4: pa 0x... size 16384 KiB
agnic0: MSI-X: N vector(s) advertised
agnic0: barmap @BAR2+0xffe000: version 0x00000005 cookie 0xd0fac10d [COOKIE+VER OK]
agnic0:   facility[0..4]: ...
agnic0: P2b: CTRL @BAR2+0x..., GIU @BAR0+0x0
agnic0: P2b: ctrl_map cookie 0xafacafac OK
agnic0: P2b: target reports TRGT_INIT
agnic0: P2b: HOST_INIT published
agnic0: P2b: HOST_ALIVE heartbeat started (1 Hz)
agnic0: P2b: GIU DEV_READY; firmware MAC xx:xx:xx:xx:xx:xx
agnic0: P3a: mgmt rings disabled (hw.agnic.mgmt=0); control plane only
```

Record: the `platform:` line verbatim (it decides whether the model table matches), BAR
sizes, MSI-X count, the five facility lines, the firmware MAC. A `[cookie mismatch]`
means the barmap layout differs from the 116 and nothing below applies until it is
characterised.

`mvmgmt0` also comes up in this stage (P5 runs inside the CTRL handshake). Pass:

```
agnic0: P5: pcinet MGMT_NETDEV @BAR2+0x...
agnic0: P5: pcinet ready pattern seen; acking
agnic0: [Phase 5] mvmgmt0 created (MAC 00:00:12:13:14:15) ...
```

Then:

```sh
ifconfig mvmgmt0 inet6 -ifdisabled auto_linklocal up
sleep 3; dmesg | grep 'mvmgmt0 link'         # expect ESTABLISHED
ping6 -c2 ff02::1%mvmgmt0
ndp -an | grep mvmgmt0                       # the NPU's link-local
```

Record the NPU link-local. Upstream measured `fe80::7e5a:1cff:febc:48b` on two 116s;
a match means the same firmware constant, a difference is worth noting either way.

## Stage 1: management rings and echo

```sh
kldunload if_agnic          # only if the NPU has not latched rings yet (stage 0 never publishes them)
kenv hw.agnic.mgmt=1 hw.agnic.datapath=0
kldload ./if_agnic.ko
```

Pass:

```
agnic0: P3a: mgmt rings published (...)
agnic0: P3a: HOST_MGMT_READY set; waiting DEV_MGMT_READY
agnic0: P3a: DEV_MGMT_READY; mgmt rings live
agnic0: P3a: h2t mgmt doorbell latched: BAR4+0x... data 0x...
agnic0: [Phase 3a] mgmt ECHO round-trip OK (status OK); mgmt command path is live
agnic0: [Phase 3b] capabilities: flags 0x... max_buf_size N egress_dma_engines N
agnic0: P3b: datapath disabled (hw.agnic.datapath=0); mgmt channel only
```

A `DEV_MGMT_READY` timeout with stock firmware is the first real divergence between
116 and 126; record `dev_use_size` from the log and stop here. From this stage on, every
further `kldload` in the same NPU boot will time out at `DEV_MGMT_READY` (latched
rings): plan the remaining stages for one host boot, or mains-cycle between them.

## Stage 2: NPU shell over `mvmgmt0` (optional but decisive)

With `mvmgmt0` established, SSH into the NPU with the Sophos management key from
upstream (`npu-firmware/deploy/keys/mvmgt.x86` in mamoru-xgs-npu; it is Sophos's public
key, not ours). This is read-only reconnaissance:

```sh
ssh -i mvmgt.x86 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    'root@[fe80::...%mvmgmt0]' 'uname -a; cat /proc/cmdline; cat /proc/mtd; ls /dev/mmcblk0p*'
ssh ... 'ls /opt/sophos/plt/ ; cat /opt/sophos/plt/*.txt'     # platform descriptor: port map!
ssh ... 'dmesg | grep -i -E "mv88e|dsa|switch|6193|6393|6390"'
ssh ... 'ps; ip link'
```

Record the platform descriptor file (it gives `npu0.ethN.port=1:<switch port>` on the
116) and the switch SKU from dmesg. These two answer the biggest 126 unknown: how
14 front ports hang off one or two switch chips. Write nothing on the NPU.

## Stage 3: datapath with stock NPU firmware

```sh
kenv hw.agnic.datapath=1 hw.agnic.nwa=1
kldload ./if_agnic.ko
```

Pass, in order:

```
agnic0: P3b: CC_PF_INIT OK ...
agnic0: P3b: CC_PF_INGRESS_TC_ADD OK ...
agnic0: P3b: CC_PF_INGRESS_DATA_Q_ADD OK ...
agnic0: P3b: CC_PF_EGRESS_TC_ADD OK ...
agnic0: P3b: CC_PF_EGRESS_DATA_Q_ADD OK ...
agnic0: P3b: CC_PF_INIT_DONE OK
agnic0: [Phase 3b] GIU trunk datapath ready ...
agnic0: P3b: CC_PF_ENABLE OK (attempt N)
agnic0: [Phase 3b] CC_PF_LINK_STATUS: link_status=0x1 (UP)
agnic0: [Phase 4b] trunk promiscuous ON
agnic0: P4a: NW_AGENT @BAR0+0x...
agnic0: P4a: window[i]: cafebabe 00000034 ...
agnic0: P4a: NPU reports N front-panel port(s)
agnic0: P4a:  port[i] tag=0x8100 flags=... portnum=1 ... => front-panel(mng)
...
agnic0: front-panel ports: 14 (NW_AGENT discovery (highest manageable port number))
agnic0: [Phase 4b] pport demux up: port1..port14 created ...
agnic0: [Phase 3b] datapath live: RX poll every 10 ms + MSI-X dbell id 1; port1..port14 exposed
```

Record every `P4a: port[i]` line: that table is the 126's port map as the NPU sees it
(tags, MTU, which ports are internal). If `port_count` is 9, the stock firmware on the
126 reports the 116 layout and something is wrong with the assumption; if it is 14 (or
15 with an internal port), the model table is confirmed.

Then, with one cable in Port1 to a switch with a DHCP server:

```sh
ifconfig port1 up
dhclient port1                         # RX + TX both needed for a lease
sysctl dev.agnic.0.rx_frames dev.agnic.0.tx_packets dev.agnic.0.tx_dropped
tcpdump -ni port1 -c 5
```

Outcomes to expect and what they mean:

| Observation | Meaning |
|---|---|
| `rx_frames` grows, `[Phase 4b] first RX frame (...) raw: 81 00 c0 c1 ...` | RX path works with stock firmware; the prefix format matches the 116 |
| `rx_frames` stays 0, ports UP | stock firmware is not forwarding front-panel traffic to a non-Sophos host; this is the `host_breakout_complete` question (see XGS126.md) |
| `tx_packets` grows, no reply ever | upstream's finding on the 116: stock NPU drops host egress; try `sysctl dev.agnic.0.tx_hdr_mode=1` (replay a captured RX header) and `=0`, one at a time |
| DHCP lease obtained | done: the 126 works with stock firmware, which upstream never achieved on the 116 |

Set `sysctl dev.agnic.0.rx_dbg=3 dev.agnic.0.tx_dbg=3` to hex-dump the first frames.

## Stage 4: unload and reload behaviour

```sh
kldunload if_agnic         # expect "detach: resources released (no FLR; NPU left running)"
kldload ./if_agnic.ko      # expect DEV_MGMT_READY timeout on stock firmware (latched rings)
```

Record whether the reload works without a mains cycle. On the 116 it did not.

## What to send back upstream

If stage 3 reaches a DHCP lease, that is the first FreeBSD datapath verification on any
XGS and the first on stock firmware. Open a pull request against mamoru-xgs-npu with the
port table, the platform line and the exact `dmesg` extract; the runtime port count and
the RX changes are the parts that belong there.
