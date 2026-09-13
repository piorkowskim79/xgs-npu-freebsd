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

## 9. Cosmetics

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
