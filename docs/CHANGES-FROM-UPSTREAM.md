# Changes against upstream `host-driver-freebsd/`

Base: mamoru-xgs-npu commit `e4101698b32350e3e2cc8ae09ae98e9c78e2170e` (2026-09-07).
The first commit of this repository is that tree verbatim, so `git diff <first> HEAD -- driver/`
shows exactly what follows. The three ABI headers are untouched.

Each change below states the reason and where the reasoning comes from. "Linux" means
upstream `host-driver-linux/agnic_txrx.c`, which is traffic-proven on the XGS 116 and was
itself transcribed from the FreeBSD tree; where the two diverged, the FreeBSD side was
brought back to what runs.

## 1. Runtime front-panel port count (`if_agnic.c`, `if_agnic.h`, `agnic_pport.c`, `agnic_nwa.c`)

Upstream: `#define PPORT_COUNT 9` in `agnic_pport.c`, sized for the XGS 116 (8 copper + 1 SFP).
The XGS 126 has 12 copper + 2 SFP = 14 front ports; a compiled-in 9 would silently drop
frames tagged `0x8A..0x8E`.

Now: `sc->nports` is resolved once, right before the port demux is built, by
`agnic_resolve_nports()` in this order:

1. `hw.agnic.nports` if set (> 0),
2. NW_AGENT discovery: the highest physical port number among the ports the NPU marks
   manageable (`sc->nwa_maxportnum`, recorded in `agnic_nwa_bringup()`),
3. an SMBIOS model table keyed on `smbios.system.product` / `smbios.system.version`
   (116 = 9, 126 = 14, 136 = 14; only 116 is hardware-confirmed),
4. `AGNIC_DEFAULT_NPORTS` (9).

`AGNIC_MAX_PORTS` went from 16 to 32 (tag byte0 `0x81..0xA0`); every per-port array in
`agnic_pport.c` is sized by it and every loop runs to `pp->nports`. The
`front-panel ports: N (<source>)` log line says which source won.

The platform strings are logged at attach (`platform: <product> <version>`) because the
exact SMBIOS text a Sophos BIOS stamps on an XGS is Unverified; on an XG 125 Rev. 3 it
is `XG` / `125r3`. The table match is deliberately loose (product contains `XGS`,
version starts with the digits).

## 2. Staged bring-up tunables (`if_agnic.c`, `agnic_txrx.c`)

Upstream FreeBSD ran every phase unconditionally inside the config hook. Against a box
nobody has run on, that means the first `kldload` also fires `CC_PF_ENABLE`, the NW_AGENT
admin-up of all ports and the pport demux. The Linux driver had `p3` / `dp` / `mvmgmt`
parameters for exactly this reason.

Now, all read at module load (`SYSCTL_INT(..., CTLFLAG_RDTUN, ...)` under a new
`hw.agnic` node):

| Tunable | Gate |
|---|---|
| `hw.agnic.mgmt` | `agnic_mgmt_bringup()` |
| `hw.agnic.datapath` | `agnic_txrx_bringup()` + `agnic_datapath_start()` |
| `hw.agnic.mvmgmt` | both `agnic_pcinet_bringup()` call sites (hook step 2b and the ENABLE-failure fallback) |
| `hw.agnic.nwa` | `agnic_nwa_bringup()` in `agnic_datapath_start()` |
| `hw.agnic.nports` | port count override |
| `hw.agnic.rx_poll_ms` | RX poll cadence |

`hw.agnic.link_gate` (already an upstream `TUNABLE_INT`) moved under the same node as
`SYSCTL_INT` so all knobs are visible with one `sysctl hw.agnic`.

## 3. RX poll cadence: 1 Hz -> 10 ms, poll-until-empty (`agnic_txrx.c`)

Upstream FreeBSD polled the RX ring once per second and relied on the MSI-X doorbell for
anything faster, with the doorbell id itself flagged as possibly wrong
(`AGNIC_RX_DBELL_ID` comment). If the doorbell never fires, 1 Hz on a 256-entry ring is
256 frames per second. Linux polls every 10 ms and re-arms immediately after a pass that
hit the per-pass cap.

Now: `agnic_rx_poll()` reschedules with `agnic_rx_poll_ticks()` (from
`hw.agnic.rx_poll_ms`, default 10), `agnic_rx_service()` returns whether it hit the cap,
and `agnic_rx_task()` loops while it did, bounded by `AGNIC_RX_MAX_PASSES` (64).

## 4. Buffer-pool refill toward full (`agnic_txrx.c`)

Upstream FreeBSD refilled exactly `n` slots after reaping `n` completions and only when
`n > 0`. A transient `m_getcl()` or busdma failure therefore shrank the pool for good, and
a device that had run out of buffers posts no completions, so the refill never ran again.
Linux drives the pool toward full on every pass using the device's consumer index.

Now: `agnic_bp_refill_locked()` reads `BP_CONS` from BAR0, posts fresh clusters from
`prod_shadow` up to one behind it, stops at the first device-owned slot or allocation
failure, and runs on every pass even when `n == 0`.

## 5. MSI-X id only when a vector is armed (`agnic_txrx.c`)

Upstream always advertised `msix_id = 1` in `CC_PF_INGRESS_DATA_Q_ADD`. If MSI-X
allocation had failed or fewer vectors were armed, the device would raise an interrupt
toward a vector nobody handles. Linux passes 0 in that case. Now:
`qc.msix_id = (sc->dbell_nvec > AGNIC_RX_DBELL_ID) ? AGNIC_RX_DBELL_ID : 0`.

## 6. Datapath marked live after the port interfaces exist (`agnic_txrx.c`)

Upstream set `if_running = 1` and started the poll right after `CC_PF_ENABLE`, before the
NW_AGENT bring-up and before `agnic_pport_bringup()`; frames reaped in that window were
freed because `sc->pport` was still NULL, and the NW_AGENT wait can take up to 24 s.
Linux creates the port netdevs first and only then marks the datapath live.

Now the order in `agnic_datapath_start()` is: ENABLE, link-status query, PROMISC,
NW_AGENT (if enabled), `agnic_resolve_nports()`, pport demux, `mvmgmt0` (if enabled),
and only then `if_running = 1` + poll start. Frames that arrive earlier wait in the RX
ring (the device stalls harmlessly when the pool is exhausted) and drain on the first
pass.

## 7. Drain pause after `CC_PF_DISABLE` (`agnic_txrx.c`)

Upstream freed the bpool clusters immediately after the fire-and-forget DISABLE. Linux
sleeps 100 ms first because a still-forwarding NPU may have frames in flight; without the
pause the device DMAs into freed memory (the IOMMU blocks it, but it storms the log).
Now `agnic_stop()` pauses `hz/10` when it actually sent DISABLE.

## 8. RX completion bounds (`agnic_txrx.c`)

Added the Linux check `host_headroom + pkt_offset + len <= buf_size` next to the existing
`len <= buf_size`, so a bogus `pkt_offset` cannot make `m_adj()` + length exceed the
cluster.

## 9. Stale-session handling after a host reload (`agnic_mgmt.c`, `agnic_pcinet.c`)

Measured on the XGS 126 (2026-09-13): after `kldunload`/`kldload` the NPU keeps
`HOST_MGMT_READY`/`DEV_MGMT_READY` set and polls the previous rings, so the reload passes
the handshake and then every mgmt command times out; `mvmgmt0` finds no ready pattern
either (status 0, old ring pointers still in the descriptor). Now the mgmt bring-up
clears a pre-set `HOST_MGMT_READY` and waits briefly before republishing, and the pcinet
bring-up re-uses the mailbox when it holds stale pointers. Whether the stock NPU firmware
reacts is Unverified; a mains cycle remains the known-good recovery.

## 10. Cosmetics

Device description now reads "Marvell AGNIC GIU-NIC (Sophos XGS NPU, PF)"; log lines that
said `port1..port9` say `port1..portN`.

## Not changed, on purpose

- No FLR, no reset path, no `pci_reset`. Same rule as upstream: an FLR takes the live NPU
  firmware down and the box needs a mains cycle.
- The 66-byte pport prefix, the `0xC0 + k` TX header fill (`tx_hdr_mode 3`), the
  `CC_PF_INIT` frame size of 1584 and the 36-bit DMA ceiling: all unchanged, they are the
  measured contract.
- `agnic_nwa.c` is kept and on by default: with stock Sophos NPU firmware it is the only
  path to port discovery, admin-up and real carrier. Upstream's `dp_fwd` firmware answers
  it with empty records; `hw.agnic.nwa=0` skips it for that case.
- The bring-up still runs inside `config_intrhook`, so a slow NPU delays boot (bounded:
  every wait has a timeout). OPNsense needs the port ifnets before interface assignment,
  which is why upstream chose this; revisit if boot time becomes a problem.
- `mvmgmt0` still has the fixed MAC `00:00:12:13:14:15` and the ports still use
  `02:81:00:00:00:NN`. Two XGS boxes on one L2 segment would collide; the Linux driver
  derives a per-unit middle from DMI. Worth porting once the datapath is proven.

## 11. RX-ring resync + reap guard on reattach (`agnic_txrx.c`, `if_agnic.h`)

Measured on the XGS 126 (2026-09-13): a `kldunload`/`kldload` over a still-running NPU data
plane (`dp_fwd`) sent `agnic_rx_service()` into a runaway -- `RX frames delivered: 1
(+256 this pass, N dropped)` without end, a pinned core, a flooded console, and a `kldunload`
that never returned (the box needed a mains cycle). Cause: bring-up hard-zeroes the six BAR0
index words and the ring shadows, but the device keeps its own nonzero producer/consumer
cursors from the prior session; the RX consumer (0) then never meets the device producer.
Two coordinated fixes:

- **Reap guard.** `agnic_rx_service()` read the device RX producer raw; an out-of-range value
  made `cons_shadow != prod` unsatisfiable, so the loop always hit its `guard < count` cap and
  `more = (guard >= count)` latched true forever, re-arming the poll endlessly and blocking
  detach. The producer is now masked `& (rx->count - 1)` (as `agnic_bp_refill_locked` already
  did for the bpool), and `more` is re-derived from a fresh masked producer read
  (`cons_shadow != prod`) instead of the cap. A masked producer is in `[0,count)`, so the loop
  provably converges on `cons == prod` in at most `count-1` steps and can never spin; the TX
  consumer read in `agnic_giu_tx()` is masked the same way. This alone stops the wedge.

- **Reattach resync.** New `agnic_txrx_resync_indices()`, called from `agnic_datapath_start()`
  right after `CC_PF_ENABLE` and before promisc/NW_AGENT/pport bring-up, adopts the device's
  live RX-producer / TX-consumer / bpool-consumer into the host shadows so a reattach starts
  aligned with `dp_fwd` and yields a healthy session, not merely a non-fatal one. On a genuine
  fresh load every device word reads 0 (pre-promisc the NPU forwards nothing), so it is a
  strict no-op -- the ordering (after ENABLE, before promisc) is load-bearing and documented at
  the call site. A power-of-two `CTASSERT` on the ring lengths guards the `& (count-1)` modulo.

The guard is the safety guarantee (a reattach can never wedge the host again, even if the
device indices are garbage or `dp_fwd` ignores the re-registered ring); the resync is the
correctness half (healthy RX/TX after a reattach). Both are no-ops on the proven-good
fresh-load path. Built and symbol-checked (127/127) against 15.1-RELEASE; not yet run.

## 12. DSA device 0 on the 126 + host->front counter export (`build-dp_fwd-on-pi.sh`, `agnic_pport.c`, `agnic_txrx.c`, `if_agnic.h`)

Measured on the XGS 126 (2026-09-13, night) and now **hardware-verified end to end**. Two coupled changes:

- **DSA device 0.** The 126's RX frames carry DSA byte0 `0xc0` = switch device **0** (the 116 uses
  device 2). `dp_fwd`'s `FROM_CPU` egress tag is built for `DSA_DEV` (default 0 in
  `build-dp_fwd-on-pi.sh`, `2` only for the 116). With device 2 the 88E6193X silently dropped the
  CPU-origin frame before the front jack; with device 0 it forwards. This was the entire TX-egress
  fault — not the switch config, and not the forwarder or host driver.

- **Counter export without `mvmgmt0`.** `dp_fwd` writes its four host->front counters
  (`giu_rx`/`pp2_tx`/`h2t_drop`/`egr_full_drop`) into the reserved in-band metadata bytes (offset
  0x30) of every RX frame; `agnic_pport.c` reads them in the RX demux before the prefix is stripped
  and stores them in `struct agnic_softc`; `agnic_txrx.c` exposes them as
  `dev.agnic.0.npu_giu_rx / npu_pp2_tx / npu_h2t_drop / npu_egr_drop`. This makes the decisive TX
  measurement readable straight from the host, without needing `mvmgmt0` alive during the burst.

**Verified 2026-09-13 night** with the reattach fix (#11), device-0 `dp_fwd` (`45dcb658`) and the
counter driver (`48d03df5`) on the self-starting stick: clean warm reload (no storm, `mvmgmt0`
survived), then **DHCP lease from the home-LAN router on `port1` and 15/15 ICMP round-trips, 0%
loss**, with `npu_giu_rx == npu_pp2_tx`, all drops 0. RX and TX both proven through the stock 126
switch. Changes #11 and #12 are together the datapath proof the project was blocked on. The only
remaining work for durable operation is persistence (dp_fwd in an NPU rootfs), not egress.
