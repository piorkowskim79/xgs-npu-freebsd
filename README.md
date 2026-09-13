# xgs-npu-freebsd

FreeBSD / OPNsense driver work for the Marvell AGNIC PCIe endpoint (`11ab:7080`)
that the CN9130 "NPU" of a **Sophos XGS** desktop appliance presents to the x86 host,
plus the OPNsense packaging around it.

Target box for this repository: the **Sophos XGS 126** (12 x GbE copper, 2 x SFP,
AMD Ryzen Embedded R1000 host). Everything here is derived from
[samuelleb11/mamoru-xgs-npu](https://github.com/samuelleb11/mamoru-xgs-npu), whose
FreeBSD driver `if_agnic` was measured on an XGS 116 (control plane) and whose Linux
driver carries traffic there. As of 2026-09-13 the driver has run on an XGS 126 and carries front-panel traffic in both directions as a live (RAM-only) system; see the Status table and [docs/XGS126.md](docs/XGS126.md).

## Read this first: what the hardware is

The front jacks of an XGS are **not** NICs the host can drive. They sit behind a
Marvell switch that hangs off a second computer, the CN9130 NPU, which runs its own
Linux from its own eMMC. The NPU multiplexes every front port onto **one** PCIe DMA
trunk (the AGNIC "GIU"). A host driver has to

1. talk the AGNIC control ABI (barmap, CTRL handshake, mgmt rings) to the NPU,
2. run the RX/TX/buffer-pool rings of that single trunk, and
3. demultiplex the trunk into per-port interfaces using a 66-byte per-frame prefix
   (`byte0 = 0x81 + port_index`).

Forwarding is **not** offloaded: every frame crosses PCIe to the host and back.
Whether the *stock* Sophos NPU firmware forwards front-panel traffic to a non-Sophos
host is the central open question for the XGS 126; upstream ended up replacing the
NPU data plane (`dp_fwd`) to carry traffic on the 116, and that replacement is
116-specific and needs an NPU rootfs of your own. See [docs/XGS126.md](docs/XGS126.md).

## Status

| Piece | State on XGS 126 | Evidence |
|---|---|---|
| PCI endpoint `11ab:7080` present | **Measured** | GRUB `lspci` on the box, 2026-09-13 |
| BAR sizes 1M / 16M / 16M, 16 MSI-X | **Measured** | first run, 2026-09-13 |
| Driver builds for FreeBSD 15.1 | **Cross-built and symbol-checked** (`build/if_agnic.ko`) | `tools/crossbuild-ko.sh` (unity build with clang, no FreeBSD host); every external symbol resolved against the 15.1-RELEASE GENERIC kernel (`tools/elfsyms.py`) |
| Live test stick (FreeBSD 15.1 memstick + driver + stage script) | **Booted on the 126**, serial console, driver loaded | `tools/mkstick.sh`; [docs/TESTBED.md](docs/TESTBED.md) |
| Control plane (barmap, CTRL, mgmt echo, INIT..ENABLE, link up) | **Measured OK** with stock NPU firmware | [docs/XGS126.md](docs/XGS126.md) |
| `mvmgmt0` link to the NPU, SSH into it | **Measured OK** | same link-local as the 116 |
| NW_AGENT port discovery (gives the 126 port table) | **Measured**: 16 entries, 14 usable (10 switch ports incl. 2 SFP, 4 SoC ports `eth1`–`eth4`) | [docs/XGS126.md](docs/XGS126.md) |
| RX datapath, stock NPU firmware | **Measured: 0 frames** | Sophos `usfp` forwards nothing without its host-side tables |
| RX datapath, `dp_fwd` on the NPU | **Measured: works** (real LAN frame decoded on `port1`, 2026-09-13) | [docs/XGS126.md](docs/XGS126.md) |
| TX datapath to the front jacks, `dp_fwd` on the NPU | **Measured: works** — DHCP lease + 15/15 ping to a LAN host through the stock switch, 2026-09-13 | [docs/XGS126.md](docs/XGS126.md), [docs/CHANGES-FROM-UPSTREAM.md](docs/CHANGES-FROM-UPSTREAM.md) §12 |
| Host reload against a running `dp_fwd` | **Measured OK**: RX-ring reattach fix ends the storm; `mvmgmt0` survives, clean warm handshake | [docs/CHANGES-FROM-UPSTREAM.md](docs/CHANGES-FROM-UPSTREAM.md) §11 |
| Replacement NPU data plane (`dp_fwd`) | **Measured: RX and TX both work** through the stock switch; egress solved by DSA device 0 | [docs/NPU-BUILD.md](docs/NPU-BUILD.md), [docs/XGS126.md](docs/XGS126.md) |
| Persistence / durable operation | **Open**: `dp_fwd` is volatile in `/tmp`; the NPU relaunches stock `usfp` when it exits, and a host reboot resets the NPU. Needs `dp_fwd` in an NPU rootfs of your own | [docs/XGS126.md](docs/XGS126.md) |
| OPNsense port + plugin | Written, not built | see [docs/OPNSENSE.md](docs/OPNSENSE.md) |

The honest summary: on an XGS 126, with the replacement NPU data plane `dp_fwd` running (built
from upstream's forwarder, tagged for switch device 0) and the FreeBSD `if_agnic` driver here, the
front ports carry real traffic in both directions — a DHCP lease and sustained ping round-trips
through the stock Marvell switch, 2026-09-13. With Sophos's own NPU firmware (`usfp`) no traffic
flows, as expected. **Two constraints are load-bearing and unsolved:**

1. **Live-system only, no persistence.** `dp_fwd` runs from the NPU's `/tmp` (its rootfs is
   read-only) and the FreeBSD side boots from a RAM-only USB stick. When `dp_fwd` exits, the NPU's
   own startup supervision relaunches the stock `usfp` stack and the front ports go quiet; a host
   reboot resets the NPU over PCIe, so `/tmp` cannot persist across it. Durable operation needs
   `dp_fwd` installed in an NPU rootfs of your own —
   not done.
2. **You must supply the Sophos NPU management key.** The kit talks to the NPU over `mvmgmt0` with
   Sophos's public management SSH key, which is **not** shipped here. Without it there is no way to
   stage `dp_fwd` onto the NPU.

So this is a proven data path and a usable live-system testbed, **not** a turnkey or persistent
OPNsense NIC yet. The remaining work is persistence and packaging, not the datapath.

## What changed against upstream

The driver in `driver/` is upstream `host-driver-freebsd/` (BSD-2-Clause) with a
focused set of changes, each listed with its reason in
[docs/CHANGES-FROM-UPSTREAM.md](docs/CHANGES-FROM-UPSTREAM.md):

- **Runtime port count** instead of a compiled-in `PPORT_COUNT 9`: NW_AGENT
  discovery, else an SMBIOS model table (116 = 9, 126 = 14, 136 = 14), else 9;
  overridable with `hw.agnic.nports`.
- **Staged bring-up tunables** `hw.agnic.mgmt`, `hw.agnic.datapath`,
  `hw.agnic.mvmgmt`, `hw.agnic.nwa`, so a never-seen box can be approached one
  phase at a time (upstream FreeBSD had no such switches; Linux had `p3`/`dp`/`mvmgmt`).
- **RX servicing aligned with the traffic-proven Linux driver**: 10 ms poll with
  poll-until-empty instead of 1 Hz, self-healing buffer-pool refill toward full,
  MSI-X id only advertised when a vector was actually armed, datapath marked live
  only after the port interfaces exist, drain pause after `CC_PF_DISABLE`.

## Quick start (FreeBSD 15.1 host with `/usr/src`)

```sh
cd driver
make                       # -> if_agnic.ko (bsd.kmod.mk, needs /usr/src/sys)
kenv hw.agnic.datapath=0   # first run: control plane + mgmt only
kldload ./if_agnic.ko
dmesg | tail -60
```

Then follow [docs/TESTPLAN.md](docs/TESTPLAN.md) stage by stage. Preparing the XGS 126
itself as a FreeBSD lab box is [docs/TESTBED.md](docs/TESTBED.md).

Without a FreeBSD host, `tools/syntax-check.sh` type-checks the sources against a
sparse checkout of the FreeBSD kernel tree with any clang (macOS/Linux). It is a
gate, not a build.

## Tunables

All are loader tunables (`/boot/loader.conf` or `kenv` before `kldload`) and show up
under `sysctl hw.agnic`.

| Tunable | Default | Meaning |
|---|---|---|
| `hw.agnic.mgmt` | 1 | bring up the mgmt cmd/notif rings (P3a); 0 = stop after the CTRL handshake |
| `hw.agnic.datapath` | 1 | bring up and auto-start the GIU datapath and `port1..portN`; 0 = mgmt channel only |
| `hw.agnic.mvmgmt` | 1 | create `mvmgmt0`, the PCIe management link to the NPU |
| `hw.agnic.nwa` | 1 | drive the NW_AGENT mailbox (port discovery, admin-up, link poll); stock NPU firmware only |
| `hw.agnic.nports` | 0 | front-panel ports to expose; 0 = auto |
| `hw.agnic.rx_poll_ms` | 10 | RX poll interval; the MSI-X doorbell is the fast path |
| `hw.agnic.link_gate` | 1 | carrier policy: 0 never demote, 1 demote only after first seen UP, 2 trust the NPU |

Per-device counters and the TX-header experiments live under `dev.agnic.0`.

## Repository layout

| Path | What | Licence |
|---|---|---|
| `driver/` | `if_agnic` kernel module (newbus + `if(9)`, no iflib) | BSD-2-Clause |
| `opnsense/ports/net/agnic-kmod/` | FreeBSD/OPNsense ports skeleton that builds the module | MIT |
| `opnsense/plugins/net/agnic/` | `os-agnic` plugin: depends on the kmod, loads it at boot | MIT |
| `tools/probe.sh` | endpoint check (PCI id + BARs) from upstream | MIT |
| `tools/syntax-check.sh` | clang type-check against a FreeBSD `sys/` tree | MIT |
| `tools/crossbuild-ko.sh` | build `if_agnic.ko` on macOS/Linux with clang (unity build; a kmod is an ET_REL object, no linker needed) | MIT |
| `tools/elfsyms.py` | check the module's imports against the GENERIC kernel's exported symbols | MIT |
| `tools/ufs2tool.py`, `tools/fat16tool.py` | read (and same-length patch) UFS2 / read FAT16 inside a raw image, from any host | MIT |
| `tools/mkstick.sh` | build the live test stick from the stock 15.1 memstick image: serial console + driver + stage script | MIT |
| `build/` (git-ignored) | `if_agnic.ko`, the stick image, `SHA256SUMS` | — |
| `npu/build-dp_fwd-on-pi.sh` | native, static, pinned build of upstream's NPU data plane (`dp_fwd`) on an aarch64 Linux host (Raspberry Pi 5) | MIT |
| `npu/xgs-wlan.sh`, `npu/xgs-ssh.sh` | live stick: join a WLAN through a USB adapter, start a key-only `sshd` from `/tmp` | MIT |
| `npu/npu-run-dp_fwd.sh`, `npu/xgs-fetch-and-relay.sh` | volatile `dp_fwd` test from the NPU's `/tmp`: NPU-side start/stop, host-side fetch + relay over `mvmgmt0` (untested) | MIT |
| `docs/` | changes, test bed, test plan, OPNsense integration, XGS 126 facts, NPU build | MIT |

## Relationship to upstream

The first commit of this repository is a verbatim import of
`host-driver-freebsd/` from mamoru-xgs-npu at commit `e4101698` (2026-09-07). The
ABI headers (`agnic_barmap.h`, `agnic_ctrl.h`, `agnic_giu.h`) are untouched and remain
the OS-independent statement of the NPU contract. Changes that prove out on the 126
are meant to go back upstream as pull requests; this repository is a staging area,
not a fork with ambitions of its own. Upstream's NPU firmware half
(`npu-firmware/`) is deliberately **not** copied here: it is 116-tuned, and running its
switch bring-up on another board can bridge front ports into a loop.

## Licensing

`driver/` is BSD-2-Clause (upstream copyright The Mamoru Project; modifications
copyright Michael Piorkowski). Everything else here is MIT. Full texts in
[`LICENSES/`](LICENSES/), map in [`LICENSE`](LICENSE). No vendor material is included:
the NPU base OS, `mv_armada_ep`, the Marvell UIO modules and Sophos keys stay on your
own appliance.

## Contributing

State what you ran on which box (model, FreeBSD/OPNsense version, NPU firmware:
stock or `dp_fwd`) and paste the `platform:` and `front-panel ports:` lines from
`dmesg`. Sign off commits (`git commit -s`). Never add an FLR or reset path to the
driver: an FLR takes the live NPU firmware down and the box needs a mains cycle.
