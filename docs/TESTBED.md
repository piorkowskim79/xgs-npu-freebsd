# Test bed: the Sophos XGS 126 as a FreeBSD lab box

Goal: a plain FreeBSD 15.1-RELEASE on the XGS 126 that can be reached over SSH, builds
kernel modules itself, and leaves the Sophos installation untouched so the box can go
back to being a Sophos appliance. OPNsense 26.7 is FreeBSD 15.1-RELEASE-p1 based, so a
module that works on plain 15.1 is the right first target; packaging for OPNsense is a
separate step ([OPNSENSE.md](OPNSENSE.md)).

Facts about the box used below come from the project fact sheets (Sophos manuals, the
GRUB `lspci` run on 2026-09-13); items marked *check* have not been confirmed on this unit.

## What the box gives you

| Item | Value | Source |
|---|---|---|
| Host CPU / RAM | AMD Ryzen Embedded R1000 family, 6 GB | manual; PCI ids measured |
| Storage | 64 GB M.2, SATA (AMD `1022:7901` AHCI at 03:00.0) | measured |
| NPU | Marvell, PCI `11ab:7080` at 01:00.0, the only network device | measured |
| Console | micro-USB (FTDI) in front, RJ45 COM at the back; micro-USB wins when both are cabled | manual |
| Console speed | **38400 8N1** in the Sophos BIOS phase; FreeBSD/OPNsense loaders default to **115200** | manual / OPNsense docs |
| BIOS | AMI, setup key **Delete** (*check*), Legacy vs UEFI mode unknown (*check*) | partner KB |
| USB | 1 x USB 2.0 front, 1 x USB 3.0 back | manual |
| Stock boot | GRUB 2.06, Sophos Firewall OS 22.0, "Checking for NPU uboot mismatch" | measured |

## Storage decision: keep SFOS intact

Do not install onto the internal M.2. Two clean options:

1. **USB SSD or a fast USB stick (32 GB+) in the rear USB 3.0 port** as the FreeBSD
   system disk. Nothing on the M.2 changes; pull the USB disk and the box boots SFOS
   again. Simplest and fully reversible. USB storage as a lab root is fine; it is only
   unsuitable for a production firewall.
2. **Swap the M.2 SATA module** for a spare (2242/2280 form factor: *check* by opening
   the case) and keep the Sophos module in an antistatic bag. Faster, still reversible,
   costs a spare module.

Either way the NPU is unaffected: it boots from its own eMMC regardless of what the x86
side runs, and the driver never resets it.

## Installing FreeBSD 15.1

1. On the Mac, fetch and write the memstick image (the `.xz` is ~116 MB for
   mini-memstick, which needs network during install; the full memstick is ~900 MB
   compressed and installs offline):

   ```sh
   curl -O https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-amd64-memstick.img.xz
   xz -d FreeBSD-15.1-RELEASE-amd64-memstick.img.xz
   diskutil list                              # find the stick, e.g. /dev/disk4
   diskutil unmountDisk /dev/disk4
   sudo dd if=FreeBSD-15.1-RELEASE-amd64-memstick.img of=/dev/rdisk4 bs=1m
   ```

2. Console from the Mac, two speeds because the BIOS and the loader differ:

   ```sh
   ls /dev/cu.usbserial-*
   screen /dev/cu.usbserial-XXXX 38400      # BIOS / boot menu
   # later, once the FreeBSD loader takes over:
   screen /dev/cu.usbserial-XXXX 115200
   ```

   Leave `screen` with `Ctrl-A` then `k`. If the loader prints and then goes silent,
   the BIOS console redirection and the loader disagree on the UART; try the RJ45 COM
   or set `comconsole_port` at the loader prompt.

3. Installer stick in the **front** USB 2.0 port, target disk in the **rear** USB 3.0
   port, power on, hammer **Delete** on the serial console for the BIOS. Use the
   one-time boot override for the installer stick; do not change the permanent boot
   order yet. Note the BIOS version, boot mode (UEFI/Legacy) and whether Secure Boot
   exists; the FreeBSD loader is not Microsoft-signed, so Secure Boot must be off.

4. In `bsdinstall`:
   - Distribution sets: **base, kernel, src** (the module build needs `/usr/src/sys`),
     optionally `lib32` off, `ports` off.
   - Partitioning: **UFS**, GPT, the whole target disk (ZFS works too but UFS is
     lighter on 6 GB and simpler to image).
   - Hostname e.g. `xgs126-lab`.
   - Network: the installer will find **no** interface unless a USB NIC is plugged
     in (see below). Skip; configure after first boot.
   - Services: enable **sshd** and **ntpd**. Disable `moused`/`dumpdev` as you like.
   - Users: create a regular user in group **wheel**; set a root password.
   - After install, in the "final modifications" shell:

     ```sh
     printf 'console="comconsole"\ncomconsole_speed="115200"\nautoboot_delay="5"\n' >> /boot/loader.conf
     ```

5. Reboot, remove the installer stick, boot the USB disk (BIOS override or boot order).
   Log in on the serial console.

## Network for remote work

The XGS 126 has no NIC FreeBSD can use until the driver works. For SSH from the Mac
you need a **USB Ethernet adapter** on the box: any RTL8153-based adapter attaches as
`ure0`, ASIX AX88179 as `axge0`, both in the GENERIC kernel. Plug it into the front
USB 2.0 port (the rear one holds the system disk) and cable it to the home LAN.

```sh
sysrc ifconfig_ure0="DHCP"          # or axge0
service netif restart ure0
ifconfig ure0                       # note the address
```

Then from the Mac:

```sh
ssh mike@<address>
```

Put the Mac's public key into `~/.ssh/authorized_keys` on the box. `sudo` is not in
base; either `pkg install sudo` (needs internet through the USB NIC) or use `su`.
A DHCP reservation on the home router keeps the address stable across reboots.

Worth installing once online: `pkg install git sudo pciutils` (`pciutils` gives
`lspci` for a second opinion next to `pciconf`).

## First things to record

Paste these into the test log; the driver's model table and the port map for the 126
depend on them.

```sh
kenv | grep -E 'smbios\.(system|bios)\.'
sysctl hw.model hw.ncpu hw.physmem machdep.bootmethod
pciconf -lbv | grep -A6 'chip=0x708011ab'      # BAR sizes: expect 1M/16M/16M
sh tools/probe.sh
ls /dev/ttyu*                                  # the NPU console is on one of these
```

The NPU serial console is the host's third UART on the 116 (`ttyS2` on Linux, `ttyu2`
on FreeBSD). Whether the 126 wires it the same way is *check*: `cu -l /dev/ttyu2 -s
115200` and a reset of the NPU (or just waiting for its log chatter) tells.

## The development loop

From the Mac, with the repository checked out:

```sh
rsync -a --exclude .git driver/ mike@xgs:driver/
ssh mike@xgs 'cd driver && make clean && make 2>&1 | tail -20'
ssh -t mike@xgs 'sudo kenv hw.agnic.datapath=0 && sudo kldload ./driver/if_agnic.ko; dmesg | tail -60'
```

Unload with `sudo kldunload if_agnic`. The driver's detach releases resources without
an FLR, so load/unload cycles are cheap. What is **not** cheap: the NPU latches the mgmt
ring addresses once per NPU boot (upstream measurement), so after a `kldunload` that
happened past the P3a handshake, expect the next load to time out at
`DEV_MGMT_READY` until the NPU is rebooted. Rebooting the host also reboots nothing on
the NPU; a mains cycle does.

## Going back to Sophos

Unplug the USB disk (or refit the original M.2). SFOS boots from the M.2 as before. The
NPU was never written to by anything in this repository.
