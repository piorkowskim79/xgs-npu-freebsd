# OPNsense integration

OPNsense 26.7 "Xenial Xenops" is built on FreeBSD 15.1-RELEASE-p1 plus stable/15
networking commits. `if_agnic` targets exactly that, so no API shim is needed. What
OPNsense needs on top of a working module is packaging, a boot-time load, and an
interface story that survives its own boot sequence.

## How OPNsense ships out-of-tree kernel modules

The precedent is the Realtek vendor driver:

- a **port** `net/realtek-re-kmod` in `opnsense/ports` (`USES= kmod`, `USE_GITHUB`,
  `PLIST_FILES= ${KMODDIR}/if_re.ko`) builds `if_re.ko` against the OPNsense kernel
  source and installs it to `/boot/modules/`;
- a **plugin** `net/realtek-re` in `opnsense/plugins` (`PLUGIN_DEPENDS= realtek-re-kmod`)
  is the `os-realtek-re` package the GUI installs; its only payload is
  `src/etc/rc.loader.d/50-realtek-re`:

  ```
  if_re_load="YES"
  if_re_name="/boot/modules/if_re.ko"
  ```

  OPNsense assembles `/boot/loader.conf` from `rc.loader.d/` at boot, so the module is
  loaded by the loader before the kernel initialises PCI.

This repository mirrors that structure one to one:

| Here | Goes to | Package |
|---|---|---|
| `opnsense/ports/net/agnic-kmod/` | `opnsense/ports` tree, `net/agnic-kmod` | `agnic-kmod-<ver>.pkg` |
| `opnsense/plugins/net/agnic/` | `opnsense/plugins` tree, `net/agnic` | `os-agnic-<ver>.pkg` |

Both are written against the current conventions of those trees and have not been
built; `distinfo` for the port is generated with `make makesum` on a FreeBSD host once
a tagged release exists on GitHub.

## Building the packages

Fastest path, on the OPNsense box itself or any FreeBSD 15.1 host with the OPNsense
source:

```sh
opnsense-code src ports plugins            # clones opnsense/{src,ports,plugins} into /usr
cp -R opnsense/ports/net/agnic-kmod /usr/ports/net/
cp -R opnsense/plugins/net/agnic /usr/plugins/net/
cd /usr/ports/net/agnic-kmod && make makesum && make package   # -> work/pkg/agnic-kmod-*.pkg
cd /usr/plugins/net/agnic && make package                      # -> work/pkg/os-agnic-*.pkg
```

The kmod port needs `SRC_BASE=/usr/src` to point at the OPNsense kernel source
(`opnsense-code src` puts it there). The official way is `opnsense/tools` with
`make ports` and `make plugins`, which is what a release build would use; for the lab
the two `make package` calls are enough.

Install on the target:

```sh
pkg add agnic-kmod-*.pkg os-agnic-*.pkg
kldload if_agnic            # or reboot; rc.loader.d/50-agnic loads it from then on
```

For the lab box a plain `make` in `driver/` on the OPNsense host also works
(`opnsense-code src` provides `/usr/src`); copy `if_agnic.ko` to `/boot/modules/` and
add the two loader lines by hand.

## Installing OPNsense on an XGS 126

The installer will find **no** network interface: the installer kernel has no
`if_agnic` and the box has no other NIC. That is fine for a serial-console install:

1. Write the OPNsense **serial** image (`-serial-amd64.img`) to a stick; the serial
   image talks 115200 baud, the Sophos BIOS phase 38400 (see [TESTBED.md](TESTBED.md)).
2. Boot it, log in as `installer`, install to the USB disk (or a replacement M.2),
   skip interface assignment.
3. First boot: log in as root on the console, install the two packages from a second
   stick (`mount -t msdosfs /dev/da1s1 /mnt; pkg add /mnt/*.pkg`), reboot.
4. `port1..port14` and `mvmgmt0` now exist; assign in the console menu (option 1) or
   the GUI once one port carries an address.

A USB Ethernet adapter during installation shortens this (the installer can then
fetch packages), but it is not required.

## Interface assignment and boot order

OPNsense assigns interfaces from `config.xml` early in `/etc/rc`. Two properties of the
driver matter here, both inherited from upstream and kept:

- The GIU trunk has **no** OS-visible interface; only `port1..portN` and `mvmgmt0`
  exist. Otherwise the first-boot assignment would grab the trunk as LAN and never get
  DHCP.
- The datapath is auto-started inside `config_intrhook`, i.e. **before** `/etc/rc`
  runs, so the port interfaces exist when assignment happens. The cost is boot time:
  every NPU wait is bounded (2 s to 24 s each), so a dead NPU delays boot by well under
  a minute and then the box comes up without ports rather than hanging.

`mvmgmt0` shows up in the assignment list like any NIC. Leave it unassigned in
production, or assign it as an OPT interface with only a link-local address if you
want to reach the NPU from the GUI/SSH; `hw.agnic.mvmgmt=0` in a
`/boot/loader.conf.d/agnic.conf` (or the plugin's `rc.loader.d` file) removes it.

## Tunables under OPNsense

System > Settings > Tunables edits `/boot/loader.conf` for `hw.agnic.*` entries and
`sysctl.conf` for `dev.agnic.0.*`. All `hw.agnic.*` knobs are loader tunables and need a
reboot; the `dev.agnic.0.*` debug knobs are live.

## What "done" looks like

1. `os-agnic` and `agnic-kmod` packages build from `opnsense/ports` + `opnsense/plugins`
   with `opnsense/tools`.
2. A fresh OPNsense 26.7 install on an XGS 126 reaches a DHCP lease on `port1` after
   installing the two packages and rebooting.
3. The plugin is submitted to `opnsense/plugins` (tier 3, community) with the kmod port
   to `opnsense/ports`; the driver changes go upstream to mamoru-xgs-npu.

Steps 1 and 2 need the test bed. Step 3 needs step 2.

## Known gaps for a production firewall (not lab)

- **No NPU firmware persistence story**: if the stock firmware does not forward, the
  fix lives on the NPU (upstream's `dp_fwd`), and upstream has not completed a
  persistent NPU rootfs install on any box. That is weeks of NPU-side work per model.
- **Per-port carrier** with stock firmware comes from NW_AGENT polling once per second
  (`hw.agnic.link_gate`); with `dp_fwd` it is forced UP.
- **No hardware offloads**: every frame is copied on TX and RX. Fine for a branch
  office on a Ryzen R1000; do not expect the 10 Gbit/s Sophos quotes.
- **Fixed MACs** (`02:81:00:00:00:NN`, `00:00:12:13:14:15`) collide when two XGS boxes
  share an L2 segment; port the per-unit derivation from the Linux driver before that
  happens.
