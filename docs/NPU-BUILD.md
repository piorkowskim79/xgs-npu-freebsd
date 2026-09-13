# Building the NPU data plane (`dp_fwd`) on a Raspberry Pi 5

Stock Sophos NPU firmware forwards nothing to a non-Sophos host ([XGS126.md](XGS126.md):
RX stays 0 through every experiment). The way forward is upstream's replacement data plane,
`dp_fwd`: Marvell's GIU packet-echo example with upstream's front-port framing, built inside
Marvell's MUSDK. This page records how it is built here, what came out, and how it is
meant to reach the NPU. Everything under "Measured" happened on 2026-09-13; everything
under "Procedure" is written down but has not run against the XGS yet.

## Why a Pi, why static

Upstream (`npu-firmware/build/`) cross-builds on x86 in Docker with the Bootlin
`aarch64--glibc--stable-2018.11-1` toolchain, chosen because its glibc 2.27 is the NPU's,
and links `dp_fwd` dynamically. The build host here is a Raspberry Pi 5 (aarch64, Debian
13, gcc 14.2): the same architecture as the CN9130, so the distro compiler builds natively
and no toolchain download is needed. Its glibc (2.41) is far newer than the NPU's, so the
binary is linked fully static instead (`libtool -all-static`). What the NPU must provide is
then only a Linux 4.14 kernel plus the UIO/CMA devices, nothing from userland.

Two adaptations to MUSDK were needed for gcc 14 and are applied by the script, not by hand:
`configure.ac` adds `-Werror` (commented out), and three warnings gcc 14 promotes to errors
(`implicit-function-declaration`, `incompatible-pointer-types`, `int-conversion`) are
demoted back with `-Wno-error=`. The forwarder itself compiled with one benign warning.

## Measured 2026-09-13 (Pi 5 `printscan`, Debian 13.7, gcc 14.2.0)

| Item | Result |
|---|---|
| MUSDK | `MarvellEmbeddedProcessors/musdk-marvell`, branch `musdk-release-SDK-10.3.5.0-PR2` @ `278748af` (the branch upstream's `env.sh` names; it is a branch, not a tag) |
| Kit | `samuelleb11/mamoru-xgs-npu` @ `e4101698` (same revision this repository was forked from) |
| configure | `--enable-static --disable-shared --enable-dma-addr=64 --enable-pp2 --enable-giu --enable-nmp --enable-sam=no --enable-neta=no` (upstream's flags; uio-cma is the default) |
| Build time | 23 s wall clock from a clean tree, four cores |
| `dp_fwd` | ELF aarch64, statically linked, no `PT_INTERP`, ABI floor GNU/Linux 3.7, 1.3 MB stripped (3.8 MB with debug info) |
| Reproducibility | two consecutive clean runs, identical sha256 (`SOURCE_DATE_EPOCH` = kit commit time) |
| Self-test | runs on the Pi itself to the usage text (`-h`), so the binary is loadable on this architecture |
| Forwarder identity | `dp_sff_*` symbols and the `swop capability` string present: it is the forwarder, not the stock echo app |
| NPU kernel (XGS 126) | `4.14.207-10.22.03` (console log), identical to the `vermagic` of the three UIO modules in upstream's XGS 116 payload |

The last row matters: `dp_fwd` needs `musdk_cma.ko`, `mv_dmax2_uio.ko` and
`uio_pdrv_genirq.ko` on the NPU. Upstream took its copies from a stock NPU
(`/usr/lib/modules/<ver>/extra/`), and the 126 runs the same kernel build, so the copies in
upstream's payload would load on the 126 if its own were missing. On a stock 126 they are
most likely already loaded, because Sophos's `usfp` is DPDK over MUSDK and needs the same
devices; `npu-run-dp_fwd.sh status` answers that on first contact.

## What is staged on the Pi (`~/npu-build`)

```
mamoru-xgs-npu/          upstream kit @ e4101698 (sources, deploy scripts, 116 payload)
musdk/                   MUSDK checkout, built in place
out/dp_fwd               the static forwarder (this is what goes to the NPU)
out/dp_fwd.debug         same, unstripped
out/dp-nmp-config.txt    upstream's NMP config (GIU id 2, ppio-0:0 = eth0 trunk, dmax2-0..2)
out/npu-run-dp_fwd.sh    NPU-side start/stop/status script (below)
out/xgs-fetch-and-relay.sh   host-side fetch + relay script (below)
out/BUILD-INFO.txt       revisions, flags, compiler, run line, ready marker
out/SHA256SUMS           hashes of everything above plus the fallback files
out/upstream-xgs116-payload/   upstream's prebuilt dp_fwd (dynamic, glibc 2.17 floor), the three .ko, sw-init scripts, upstream rcS
out/host/if_agnic.ko     the host driver from this repository's build/, for fetching over the LAN
log-bootstrap.txt log-configure.txt log-make.txt
```

`sha256sum out/dp_fwd` from the scripted build:
`2f247d73e453c8527185470bb6d8c50f70c48ea9f597e8a8d829b8637ddf2353`. The build is bit-for-bit
reproducible: MUSDK's `mvapp.c` stamps `__DATE__`/`__TIME__` into the binary, the script pins
them through `SOURCE_DATE_EPOCH` to the kit's commit time, and two consecutive clean runs
produced the same hash.

## Rebuilding

```sh
scp npu/build-dp_fwd-on-pi.sh npu/npu-run-dp_fwd.sh printscan:~/npu-build/
ssh printscan 'sh ~/npu-build/build-dp_fwd-on-pi.sh'
```

[`npu/build-dp_fwd-on-pi.sh`](../npu/build-dp_fwd-on-pi.sh) clones or updates both trees at
the pinned revisions, cleans the MUSDK checkout, applies the two gcc-14 adaptations, drops
`forwarder.c` and the wire-contract headers into the `giu/pkt_echo` slot exactly as
upstream's `build_fwd.sh` does, builds, verifies (aarch64, static, no interpreter,
forwarder symbols) and refuses to publish anything that fails a check. It also verifies
upstream's payload against its `MANIFEST` and extracts the fallback files.

## Getting a network onto the live stick

The stick's root is read-only, so everything below lives in `/tmp` and is gone after a
reboot. Two helpers in `npu/`, both served by the Pi as well:

- [`npu/xgs-wlan.sh`](../npu/xgs-wlan.sh): joins a WPA2 network through a USB WLAN adapter
  (paste it at the serial console, it asks for SSID and passphrase). Measured 2026-09-13: a
  Netgear WNA1000M (USB `0846:9041`, RTL8188CUS) attaches as `rtwn0` with the in-tree
  driver, but on the first try the USB link flapped every few seconds (descriptor reads
  failing, "set address failed"), which is power or contact, not the driver.
- [`npu/xgs-ssh.sh`](../npu/xgs-ssh.sh): starts `sshd` with host keys and `authorized_keys`
  in `/tmp/ssh`, key-only root login. `fetch` it from the Pi once the stick has an address:
  `fetch -o /tmp/xgs-ssh.sh http://<pi>:8000/xgs-ssh.sh && sh /tmp/xgs-ssh.sh http://<pi>:8000`.
  The Pi serves `authorized_keys` next to it.

The Pi's file server is `python3 -m http.server 8000` in `~/npu-build/out`, started
detached; it does not survive a reboot of the Pi (restart it the same way).

## Procedure: first run on the XGS 126 (not yet executed)

Prerequisites: USB Ethernet adapter on the XGS host (`ure0`/`axge0`), live stick booted with
the driver up to `mvmgmt0` (stage 3 or `hw.agnic.datapath=0` + `hw.agnic.mvmgmt=1`), the
Sophos NPU key on the host at `/tmp/mvmgt.x86`, and the Pi reachable on the same LAN.

1. **Pi**: `cd ~/npu-build/out && python3 -m http.server 8000`
2. **XGS host**: `fetch http://<pi>:8000/xgs-fetch-and-relay.sh`, then
   `sh xgs-fetch-and-relay.sh http://<pi>:8000`. It fetches `dp_fwd`, the config, the NPU
   script and `SHA256SUMS` into `/tmp/dp`, verifies, streams them to the NPU's `/tmp/dp`
   through `ssh cat` (no `scp` needed on the NPU) and prints `npu-run-dp_fwd.sh status`.
3. **NPU** (`ssh -i /tmp/mvmgt.x86 root@fe80::7e5a:1cff:febc:48b%mvmgmt0`):
   `sh /tmp/dp/npu-run-dp_fwd.sh start`. This stops `usfp_startup_armada.sh` and `usfp`,
   loads any of the three modules that is not loaded, and starts
   `./dp_fwd -g 2 -i eth0 -c 1 -a 1 -f dp-nmp-config.txt --no-stat` detached, log in
   `/tmp/dp_fwd.log`, and waits up to 60 s for `GIU pkt-echo is started`. `NetAgent` and
   `UMSD_NPU` are left running: the switch stays configured by Sophos and NW_AGENT
   discovery keeps working, so `hw.agnic.nwa` stays 1.
4. **XGS host**: the previous AGNIC session died with `usfp`, so
   `kldunload if_agnic && kldload /path/if_agnic.ko` (this exercises the stale-session
   handling, or warm-reboot the host if it does not recover). Then `dhclient port1` with
   the cable in port 1 and `sysctl dev.agnic.0` / the per-port counters.
5. Record `/tmp/dp_fwd.log`, `dmesg`, the counters, in `docs/XGS126.md`.

Recovery is always the mains cycle: the NPU rootfs is read-only and `/tmp` is tmpfs, so
nothing of this survives a power cut. Do not run two `dp_fwd` (upstream: crashes the NPU),
do not use upstream's `sw-init.sh` while `UMSD_NPU` runs (two writers on the switch), and
never reset the NPU from the host.

## What this does not yet cover

- The four copper ports wired directly to the NPU SoC (`eth1`–`eth4`, NW_AGENT tags
  `0x0001`–`0x0004`): `dp_fwd` serves one PP2 port (`ppio-0:0`, the switch trunk) and
  demultiplexes by DSA source port. Those four need extra PP2 ports in the NMP config and
  forwarder logic; they come after the switch ports are proven.
- Whether the 126's switch-port-to-front-label order matches the 116's `portmap.h`; the
  NW_AGENT table in [XGS126.md](XGS126.md) is the reference to check against.
- Persistence on the NPU (a rootfs slot of our own). `/tmp` is the test mechanism only.
- The `dp-nmp-config.txt` is the 116's unchanged; buffer counts may need tuning for the
  126's memory, which is unknown until `free` is read on it.
