# XGS 126: Driver Hardening, Install Kit and Port Soak Tests — Implementation Plan (v2, council-reviewed)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `docs/XGS126.md` (newest sections last), `docs/NPU-BUILD.md`, `docs/CHANGES-FROM-UPSTREAM.md` and `docs/OPNSENSE.md` first; every fact below is measured there unless marked *Unverified*. Plan v1 was reviewed by a four-voice council on 2026-09-15 (Appendix A). v2.1, same day: scope corrected by the user — v1.0 = installable driver kit, published on GitHub and contributed upstream; no OPNsense deployment on the box (Appendix B8); lab system = unattended FreeBSD 15.1 installed from the existing live stick onto a second USB stick.

**Goal:** Turn the measured-working but volatile XGS 126 datapath (`if_agnic` on FreeBSD + `dp_fwd` on the NPU) into a durable, self-healing, **installable driver kit** for FreeBSD 15.1 and OPNsense 26.7 — published as a GitHub release and contributed to the upstream forks (mamoru-xgs-npu, opnsense/ports + plugins) — proven by load and multi-day soak tests on eight copper front ports; executed by an autonomous session with the user needed only for the physical checklist. **Installing OPNsense on the user's box is explicitly not a v1.0 goal** (Appendix B8).

**Architecture:** The NPU (CN9130, own Linux on eMMC) boots `dp_fwd` from its own storage (slot p2 + `/persistent/dp`, with a respawn loop) before the x86 host attaches; the host driver `if_agnic` creates the port interfaces at attach regardless of NPU state, does one clean handshake when the NPU is ready, and a userland watchdog re-attaches on the measured reload path whenever the NPU session is lost. An install kit packages both halves (host: kmod + rc script + CLI; NPU: slot installer with a self-reverting one-shot boot) and a Pi-hosted test suite exercises the ports independently of any AI session.

**Tech Stack:** FreeBSD 15.1-RELEASE (GENERIC; unattended `bsdinstall script` from the existing live stick onto a second USB medium as the lab system) / OPNsense 26.7 as packaging target, C (newbus kmod), POSIX sh, Python 3 (reports), iperf3, Raspberry Pi 5 `printscan` (Debian 13, aarch64) as build host, console host and traffic partner, MUSDK `dp_fwd` (static aarch64).

---

## Kurzfassung für Mike (Deutsch)

**Was der Plan liefert (v1.0):** einen **installierbaren Treiber**, veröffentlicht auf GitHub und eingebracht in die Forks — **keine OPNsense-Installation auf deiner Box**. Im Einzelnen: (1) Persistentes dp_fwd auf der NPU (Slot p2) live, mit Respawn und einem selbst-zurücksetzenden Einmal-Boot als Rückweg. (2) Ein Host, der auch ohne NPU sauber bootet (Port-Interfaces existieren immer) und sich nach einem NPU-Neustart selbst neu verbindet. (3) Das Installationskit: ein Befehl für einen FreeBSD- oder OPNsense-Host (Modul, Boot-Laden, Dienst, `agnicctl`), ein Befehl für die NPU (Payload, Hook, Umschalten, Prüfen, Rollback), dazu das OPNsense-Port/Plugin-Paar und ein GitHub-Release mit vorgebautem Modul. Getestet wird das Kit auf einem **unbeaufsichtigt installierten FreeBSD 15.1** (der vorhandene Live-Stick ist die Installationsquelle, ein zweiter Stick das Ziel; kein Curses). (4) Eine Testsuite auf dem Pi für die acht Kupferports: Funktion, Durchsatz, Paketrate, Latenz, 24-h- und 72-h-Dauerlauf mit Link-Flaps, Neuladungen, NPU-/Host-Neustarts und Netzstecker — wie im Firewall-Alltag. (5) Upstream-Einreichung (nur mit deinem Go).

**Was in v1.1 verschoben wurde (Council):** eindeutige MACs pro Gerät, Jumbo-Frames, die vier SoC-Ports (eth1–eth4), Performance-Tuning, Weiterleitungstest über zwei Segmente, Kernel-interner Watchdog, händische FreeBSD-Installation.

**Ehrlichkeit vorab:** Phase 4 misst die Box als Multi-Port-NIC auf **einem** L2-Segment; ein echter Routing-/Firewall-Test braucht ein zweites Segment (v1.1, Task B6). Das steht so auch im README.

**Was nur du tun musst:** die Mike-Checkliste unten, einmal am Anfang, plus zwei Netzstecker-Zyklen zu genannten Zeitpunkten (Gate 1 und Stunde 36 des 72-h-Laufs). Danach braucht der Plan keine Eingaben; jede Aufgabe hat Pass/Fail und Rückweg, jede Phase endet mit Commit und Eintrag in `docs/XGS126.md`.

**Sicherheitsregeln (unverändert):** NPU nie per FLR/`devctl reset` zurücksetzen; `mtd0` (U-Boot) nie schreiben (`mtd1` = Umgebung ist erlaubt); den **laufenden** Slot nie beschreiben; Netzstecker ist der letzte Rückweg; nur die Labor-126; nie zwei `dp_fwd`; kein Switch-Umbau.

### Mike-Checkliste (physisch, einmalig, vor Phase 0)

- [ ] **USB-Ethernet-Adapter** (RTL8153 = `ure0` oder AX88179 = `axge0`) in den **vorderen** USB-Port der XGS, Kabel ins Heim-LAN. Der Adapter bekommt die **feste Adresse 192.168.2.250** (außerhalb des FritzBox-DHCP-Bereichs; falls dein Pool bis .250 reicht, im Plan `XGS_IP` anpassen).
- [ ] **FTDI-Konsolenkabel** (bisher am Mac, `cu.usbserial-D30A5FY8`) **an den Pi `printscan`** umstecken. Die Konsole läuft dann als Dienst auf dem Pi und überlebt XGS-Neustarts.
- [ ] **Nur zwei USB-Ports (vorn 2.0, hinten 3.0; die Konsole ist ein eigener Micro-USB).** Während der Installation werden drei Geräte gebraucht (Live-Stick = Quelle, Zielstick, Ethernet-Adapter). Entweder **ein kleiner USB-Hub vorn** (Live-Stick + Adapter am Hub, empfohlen, bleibt dauerhaft) oder **ohne Hub**: Installation läuft ohne Netzwerk über die Pi-Konsole (`xgscon`), danach ziehst du vorn den Live-Stick und steckst den Adapter ein (einmalig). Dauerbetrieb: vorn Adapter, hinten das installierte FreeBSD.
- [ ] **Ein zweiter USB-Stick ≥ 16 GB (oder eine USB-SSD)** in den **hinteren** USB-3-Port der XGS. Warum ein zweiter: der vorhandene FreeBSD-Stick ist ein Live-System (Root read-only, alles nach Neustart weg) und dient als Installationsquelle und Rettungssystem; der Installations-Test braucht ein beschreibbares FreeBSD, das Reboots überlebt. Die Sitzung installiert es selbst, unbeaufsichtigt, vom Live-Stick aus.
- [ ] **Port1–Port8** der XGS an **einen** Switch, der ans Heim-LAN hängt; **Pi `printscan`** an denselben Switch (ein Kabel).
- [ ] Optional: eine **schaltbare Steckdose** (Smart Plug) für die XGS, damit Netzstecker-Zyklen automatisiert werden können. Ohne: du ziehst zweimal selbst (Gate 1, Stunde 36 des 72-h-Laufs); der Plan sagt dir wann.
- [ ] XGS **einschalten** (Live-Stick steckt, bootet p3/Stock).

---

## Global Constraints

- Target kernel: FreeBSD **15.1-RELEASE** GENERIC amd64 (OPNsense 26.7 = 15.1-RELEASE-p1); module built with `tools/crossbuild-ko.sh` on the Mac or `make` in `driver/` on a FreeBSD host with `/usr/src`; every build is symbol-checked with `tools/elfsyms.py` (all symbols resolved).
- NPU: CN9130, Linux `4.14.207-10.22.03`, BusyBox init (`rcS` runs `/etc/init.d/S??*` in order with `start`); rootfs read-only; `/tmp` (tmpfs) and `/persistent` (mmcblk0p4, ~76 MB free, eMMC — write sparingly, no logs) writable. Running slot **p3**, standby **p2** (identical vendor build `rootfs-2025.1113-…-Jamaica`); U-Boot env `bootcmd`/`bootargs` = `emmc3` variant; `emmc1/2/3` variants exist; `bootdelay=3`; no autorollback. `bootcmd` and `bootargs` always travel together.
- Never: FLR/`devctl reset`/`pciconf -w` on `pci0:1:0:0`; write `/dev/mtd0`; write the **running** slot; run two `dp_fwd`; run `sw-init.sh`/`dp_swcfg`; touch the second (production) XGS 126.
- `dp_fwd` binary: sha256 `45dcb6587884ff1eab4a3945bbe49fe4f556d59adcc46763d395d369837aafdf` (device-0 DSA tag + counter export), built by `npu/build-dp_fwd-on-pi.sh` on `printscan`; already present in NPU `/persistent/dp/` (verified 2026-09-14).
- Measured link limits: `mvmgmt0` carries pings and small transfers but **drops bulk streams (~19 MB)**; the RTL8188CUS WLAN stick is unreliable. Rule: NPU-side checks that fail over `mvmgmt0` are retried over the NPU serial (`tools/npucon.sh`) before they count as Fail; files to the NPU go in ≤ 1 MB chunks with per-chunk sha256 (Task 3.3) or are skipped when the target sha already matches.
- A host reboot resets the NPU (PCIe endpoint). Whether an **NPU-only** reboot under a live host is safe is *Unverified* until Task 2.0.
- Access: SSH `root@xgs` = 192.168.2.250 over the USB NIC (Mac key `~/.ssh/id_ed25519`; Pi gets its own key in Task 0.1); serial console via Pi service `xgs-console` + `xgscon`; NPU shell via `mvmgmt0` (`ssh -i mvmgt.x86 root@fe80::7e5a:1cff:febc:48b%mvmgmt0`) or NPU serial `/dev/cuau2` on the host (`tools/npucon.sh`).
- Commits: one per task, English, end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never push, tag-push, release or open PRs without the user's explicit go. Every phase appends a dated "Measured" section to `docs/XGS126.md`.
- The stick's `sshd` has no SFTP subsystem: `ssh host 'cat > file' < file`, never `scp` (or `scp -O`).
- Long-running tests are **systemd units on the Pi** (and cron on the host), never a foreground AI session; a later session evaluates the JSONL.

---

## Phase overview, order and gates (v1.0 critical path)

Order: 0 → 1 → 2.0 → 2.1 → 2.2 → 3.1 → 3.2 → 3.3 → 4.1 → 4.2 → 4.4 → 4.5 → 3.4 → 5. Appendix B holds the v1.1 backlog.

| Phase | Deliverable | Gate |
|---|---|---|
| 0 Access | fixed-IP USB-NIC SSH, Pi console service, `npucon.sh`, state snapshot | `ssh xgs uptime` and `ssh printscan "xgscon uptime"` both work across an XGS reboot |
| 1 Persistence | NPU boots `dp_fwd` from p2 with respawn; self-reverting one-shot flip; host binds it | 3 warm reboots + **1 mains cycle** → port1 lease ≤ 5 min each; `pkill dp_fwd` → new pid ≤ 10 s |
| 2 Robustness | measured NPU-reboot behaviour; ifnets exist without NPU; userland watchdog re-attach; mvmgmt0 fix | NPU reboot → lease back ≤ 3 min, no manual step; 20 reloads clean; 10× 30 MB over mvmgmt0 |
| 3 Kit | `install.sh`, rc.d `agnic_npu` (non-blocking), `agnicctl`, `npu-install.sh` with one-shot flip, unattended FreeBSD 15.1 lab install, negative test, OPNsense port+plugin packages, release tarball | FreeBSD 15.1 on the second stick + kit → reboot → 8 ports up, lease on port1; with NPU dead → still boots to SSH, no console prompt; kmod port + plugin packages build |
| 4 Tests | Pi-hosted suites: functional, perf matrix, 24 h + 72 h soak with events incl. mains cut | 72 h: 0 wedges, events recovered ≤ 3 min, no leak, counters consistent |
| 5 Publish | GitHub release `v1.0.0` (module + kit + checksums), PRs to mamoru-xgs-npu and opnsense/ports+plugins | texts and assets ready; the user gives one go for release + PRs |

**Fail** = stop, record in `docs/XGS126.md`, apply the task's rollback, continue with the next independent task or return with a new hypothesis (one at a time).

---

## Phase 0: Access that survives reboots

### Task 0.1: Fixed-IP USB-NIC SSH, Pi key, `xgs` alias

**Files:** Modify `npu/stick/autostart.sh`; Create `tools/pi/xgs-ssh-config`; Modify Mac `~/.ssh/config`.

- [ ] **Step 0 (before Mike plugs anything): confirm the stick kernel has the USB NIC drivers.** `ssh root@<current-ip> 'kldstat -v | grep -cE "ure|axge"; ls /boot/kernel/if_ure.ko /boot/kernel/if_axge.ko'` → GENERIC 15.1 builds both in; if the count is 0, add `if_ure_load="YES"` and `if_axge_load="YES"` to the stick's loader.conf via `tools/mkstick.sh` (same-length patch) — note it in `docs/XGS126.md`.
- [ ] **Step 1: autostart brings the USB NIC up first, fixed IP with DHCP fallback.** Insert after the sshd block:

```sh
# 1b. USB Ethernet adapter = the reboot-safe management path. Fixed IP (outside the DHCP pool),
#     DHCP only as fallback so a fresh session never has to discover the address.
XGS_IP=${XGS_IP:-192.168.2.250}; XGS_GW=${XGS_GW:-192.168.2.1}
for u in ure0 axge0 ue0; do
	ifconfig "$u" >/dev/null 2>&1 || continue
	ifconfig "$u" inet "$XGS_IP/24" up && route add default "$XGS_GW" 2>/dev/null
	ping -c1 -W1000 "$XGS_GW" >/dev/null 2>&1 || { ifconfig "$u" inet "$XGS_IP" -alias; timeout 40 dhclient "$u" >/dev/null 2>&1; }
	echo "usb-nic: $u $(ifconfig "$u" | awk '/inet /{print $2; exit}')  <- ssh here"
	break
done
```

- [ ] **Step 2:** Push to the stick (`ssh root@<ip> 'cat > /mnt/xgs/autostart.sh && sync' < npu/stick/autostart.sh`) and commit `stick: USB NIC first, fixed 192.168.2.250 with DHCP fallback`.
- [ ] **Step 3:** `ssh root@<ip> reboot`; after 3 min `ssh root@192.168.2.250 uptime` works.
- [ ] **Step 4: Aliases and Pi key.** Mac `~/.ssh/config`: `Host xgs` / `HostName 192.168.2.250` / `User root` / `IdentityFile ~/.ssh/id_ed25519` / `StrictHostKeyChecking no` / `UserKnownHostsFile /dev/null` / `ServerAliveInterval 5`. On the Pi: `ssh printscan 'test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q; cat ~/.ssh/id_ed25519.pub'` → append to the stick's `/mnt/xgs/authorized_keys` and to the running `/tmp/ssh/authorized_keys`; put the same `Host xgs` block into `printscan:~/.ssh/config` (repo copy `tools/pi/xgs-ssh-config`).
- [ ] **Step 5:** `ssh xgs uptime` (Mac) and `ssh printscan 'ssh xgs uptime'` both work. Commit.

**Rollback:** additive; WLAN/data-path access unchanged.

### Task 0.2: Serial console as a Pi service, with `xgscon`

**Files:** Create `tools/pi/xgs-console.service`, `tools/pi/xgscon`, `tools/pi/install-console.sh`.

- [ ] **Step 1: Unit** (bind to the stable by-id node, not `ttyUSB0`):

```ini
[Unit]
Description=XGS 126 serial console (screen, logged), survives XGS reboots
BindsTo=dev-serial-by\x2did-usb\x2dFTDI_FT232R_USB_UART_D30A5FY8\x2dif00\x2dport0.device
After=dev-serial-by\x2did-usb\x2dFTDI_FT232R_USB_UART_D30A5FY8\x2dif00\x2dport0.device

[Service]
Type=forking
ExecStart=/usr/bin/screen -dmS xgscon -L -Logfile /var/log/xgs-console.log /dev/serial/by-id/usb-FTDI_FT232R_USB_UART_D30A5FY8-if00-port0 115200
ExecStop=/usr/bin/screen -S xgscon -X quit
Restart=always
RestartSec=3
User=mike

[Install]
WantedBy=multi-user.target
```

The exact by-id name is read on the Pi with `ls /dev/serial/by-id/` after the cable is moved; `install-console.sh` substitutes it (`sed`), the value above is the expected FT232R pattern.

- [ ] **Step 2: Helper** `tools/pi/xgscon` (mode 755):

```sh
#!/bin/sh
# xgscon 'command' [timeout_s] -- type into the XGS console (screen session xgscon), read back the output.
LOG=/var/log/xgs-console.log; T=${2:-20}; id=$(date +%s)$$
screen -S xgscon -p 0 -X stuff "echo __B_$id; $1; echo __E_$id"$'\r'
i=0; while [ $i -lt $((T*2)) ]; do grep -q "^__E_$id" "$LOG" 2>/dev/null && break; sleep 0.5; i=$((i+1)); done
tr -d '\r' < "$LOG" | awk -v b="__B_$id" -v e="__E_$id" 'index($0,b)&&!index($0,"echo "){p=1;next} index($0,e)&&!index($0,"echo "){p=0} p'
grep -q "^__E_$id" "$LOG" || { echo "[xgscon: timeout ${T}s; raw tail:]"; tail -c 400 "$LOG" | tr -d '\r'; }
```

- [ ] **Step 3: Installer** `tools/pi/install-console.sh`: `apt-get install -y screen`; `install -m755 xgscon /usr/local/bin/`; substitute the by-id name into the unit; `install -m644` it to `/etc/systemd/system/`; `touch /var/log/xgs-console.log; chown mike`; `usermod -aG dialout mike`; `systemctl daemon-reload; systemctl enable --now xgs-console`; `logrotate` drop-in (weekly, 4 copies).
- [ ] **Step 4: Root autologin on the XGS console** (installed systems, Phase 3): `/etc/gettytab` entry `xgs:al=root:tc=3wire.115200`, `/etc/ttys` `ttyu0 "/usr/libexec/getty xgs" vt100 onifconsole secure`; the kit flag `--console-autologin` applies it and `docs/INSTALL.md` marks it lab-only.
- [ ] **Step 5:** `ssh printscan "xgscon 'uptime'"` → then `ssh xgs reboot` → 3 min → `xgscon 'uptime'` again shows a small uptime. Commit.

### Task 0.3: NPU console helper on the host (`tools/npucon.sh`)

- [ ] **Step 1:** `tools/npucon.sh` = the working `/tmp/nc.sh` of 2026-09-14: `stty -f /dev/cuau2.init 115200 cs8 -parenb -cstopb clocal raw -echo -ixon -ixoff -crtscts`; `daemon -o /tmp/npucon.log cat /dev/cuau2` if no reader; sends `root\r` when the log ends in `login:`; command framed by `echo __B_$id; CMD; echo __E_$id`; awk read-back ignoring the echoed line. Modes: `npucon.sh 'cmd' [T]`, `--login`, `--uboot` (send a space every 100 ms for 90 s while printing new lines; stops when `Marvell>>` appears; then accepts further U-Boot commands as `npucon.sh --uboot-cmd 'printenv bootcmd'`).
- [ ] **Step 2:** Stage via autostart (`/tmp/npucon.sh`); verify `ssh xgs 'sh /tmp/npucon.sh "uptime; cat /proc/cmdline"'` shows `root=/dev/mmcblk0p3`. Commit.

### Task 0.4: State snapshot script `tools/xgs-state.sh`

- [ ] **Step 1:** Prints host uptime, `kldstat|grep agnic`, `sysctl hw.agnic dev.agnic.0`, per-port inet + status, `netstat -ibn` for `port*`, mvmgmt0 ping; then over mvmgmt0 (fallback `npucon.sh`): `NPU: uptime`, `NPU: pidof dp_fwd usfp NetAgent UMSD_NPU`, `NPU: root=`, `NPU: dp_fwd restarts=<n>` (from `/tmp/dp-boot.log`), `NPU: tail -3 /tmp/dp_fwd.log`; never errors out. Staged to `/tmp/xgs-state.sh`. Commit. "Snapshot" below = this output pasted into `docs/XGS126.md`.

---

## Phase 1: Persistent dp_fwd goes live (slot p2)

State at start: `/persistent/dp/{dp_fwd,dp-nmp-config.txt,npu-run-dp_fwd.sh,dp-boot.sh(v1)}` present; p2 has `/etc/init.d/S99dp-fwd`; boot still `emmc3`; stick autostart binds an already-running dp_fwd.

### Task 1.1: `dp-boot.sh` v2 (owns the bring-up, respawns dp_fwd), bench-tested on p3

Design decision (council): on p2 the stock `S91xgsstartup` is **disabled** (renamed `K91xgsstartup`, which `rcS` ignores), so `dp-boot.sh` is the only data-plane bring-up and there is no parked stock stack, no double `insmod`, no second `NetAgent`. `S15watchdog` (the `/dev/watchdog` petter) stays untouched. Logs go to `/tmp` (tmpfs), not `/persistent` (eMMC wear); `/persistent/dp/dp-boot.log` is dropped.

- [ ] **Step 1: Write `npu/dp-boot.sh` v2** (repo) — module insert order of `armada_target_setup_usfp.sh`, `ifup mvmgmt0`, hugepages, `NetAgent` + `UMSD_NPU`, then a **respawn loop** around dp_fwd with a restart counter:

```sh
#!/bin/sh
# dp-boot.sh v2 -- persistent dp_fwd bring-up on the XGS 126 NPU (slot p2; S91xgsstartup disabled there).
LOG=/tmp/dp-boot.log; DP=/persistent/dp; X=/usr/lib/modules/$(uname -r)/extra; MRVL=/usr/marvell
exec >>$LOG 2>&1; echo "=== dp-boot v2 $(date) ==="
for m in musdk_cma mv_dmax2_uio; do modprobe $m 2>/dev/null || insmod $X/$m.ko; done
modprobe uio_pdrv_genirq of_id="generic-uio" 2>/dev/null || insmod $X/uio_pdrv_genirq.ko of_id=generic-uio
for m in mv_facility_trgt_dma mv_armada_ep mv_pcinet_trgt mv_nwa_target mvmdio_uio; do modprobe $m 2>/dev/null; done
ifup mvmgmt0 2>/dev/null
grep -q hugetlbfs /proc/mounts || { mkdir -p /mnt/huge; mount -t hugetlbfs nodev /mnt/huge; }
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
cd "$MRVL" && { stdbuf -oL ./NetAgent 2>&1 | logger -t NetAgent & stdbuf -oL UMSD_NPU 2>&1 | logger -t UMSD_NPU & }
sleep 3
cd "$DP" || exit 1
n=0; echo 0 > /tmp/dp_fwd.restarts
while :; do
	echo "dp_fwd start #$n $(date)"; echo $n > /tmp/dp_fwd.restarts
	./dp_fwd -g 2 -i eth0 -c 1 -a 1 -f dp-nmp-config.txt --no-stat >/tmp/dp_fwd.log 2>&1
	echo "dp_fwd exit rc=$? $(date)"; n=$((n+1)); sleep 3
done
```

`S99dp-fwd` stays the 8-line stub that backgrounds this script. Add `npu/S99dp-fwd` to the repo.

- [ ] **Step 2: Bench on the running p3 NPU** (the closest reachable model of "S91 disabled": stop the stock stack, then run dp-boot v2):

```sh
ssh xgs 'ssh -i /tmp/mvmgt.x86 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@fe80::7e5a:1cff:febc:48b%mvmgmt0 "sh /tmp/dp/npu-run-dp_fwd.sh stop 2>/dev/null; pkill -f armada_target_setup_usfp; pkill NetAgent; pkill UMSD_NPU; sleep 2; cat > /persistent/dp/dp-boot.sh" ' < npu/dp-boot.sh
ssh xgs 'ssh ... root@NPU "chmod +x /persistent/dp/dp-boot.sh; setsid sh /persistent/dp/dp-boot.sh & sleep 8; tail -15 /tmp/dp-boot.log; tail -3 /tmp/dp_fwd.log; pidof dp_fwd NetAgent UMSD_NPU; pidof watchdog"'
```

Pass: `GIU pkt-echo is started`, one pid each, `watchdog` petter alive. Fail branches (one at a time, record each): hugepages write fails → 512; `musdk_cma` missing → insmod path; `-i eth0` busy → start NetAgent/UMSD *after* dp_fwd.
- [ ] **Step 3: Host binds it:** `ssh xgs 'kldunload if_agnic; sleep 2; kldload /tmp/if_agnic.ko; sleep 8; ifconfig mvmgmt0 inet6 -ifdisabled auto_linklocal up; dhclient port1; sh /tmp/xgs-state.sh'` → lease, `npu_giu_rx == npu_pp2_tx`, Pi ping 0 % loss.
- [ ] **Step 4: Respawn proof:** `ssh xgs 'ssh ... root@NPU "pkill dp_fwd; sleep 8; pidof dp_fwd; cat /tmp/dp_fwd.restarts"'` → a new pid and `1`; then Step 3 again (host re-bind after a dp_fwd restart) → lease. Record the re-bind time.
- [ ] **Step 5:** Two consecutive clean runs of Steps 2–4 → commit `npu/dp-boot.sh`, `npu/S99dp-fwd`.

**Rollback:** `ssh xgs reboot` (NPU resets to stock p3).

### Task 1.2: Disable S91 on p2, self-reverting one-shot flip, watched first boot

- [ ] **Step 1: p2 edits** (over mvmgmt0; running slot must read `mmcblk0p3` first):

```sh
ssh xgs 'ssh ... root@NPU "grep -o root=[^ ]* /proc/cmdline; mkdir -p /tmp/p2; mount -o rw /dev/mmcblk0p2 /tmp/p2 && mv /tmp/p2/etc/init.d/S91xgsstartup /tmp/p2/etc/init.d/K91xgsstartup && ls /tmp/p2/etc/init.d && sync && umount /tmp/p2 && echo P2-EDITED"'
```

- [ ] **Step 2: One-shot flip that reverts itself.** From Linux, write a `bootcmd` that (a) first restores the permanent env to p3 (`saveenv` writes `mtd1`, allowed), then (b) boots p2 **once**:

```sh
ssh xgs 'ssh ... root@NPU "fw_printenv bootcmd bootargs > /persistent/dp/uboot-env-before-flip.txt; fw_setenv bootcmd \"setenv bootcmd \\\"\${bootcmd_emmc3}\\\"; setenv bootargs \\\"\${bootargs_emmc3}\\\"; saveenv; setenv bootargs \\\"\${bootargs_emmc2}\\\"; run bootcmd_emmc2\"; fw_printenv bootcmd"'
```

Read-back must show the nested `setenv … saveenv … run bootcmd_emmc2` line. Semantics: if p2 fails in any way, the next power cycle boots p3 — no console needed. Only after Task 1.3 passes is p2 made permanent (`fw_setenv bootcmd "$(fw_printenv -n bootcmd_emmc2)"; fw_setenv bootargs "$(fw_printenv -n bootargs_emmc2)"`).

- [ ] **Step 3: Boot p2 once.** Start the NPU console reader (`ssh xgs 'sh /tmp/npucon.sh "echo ok"'`), then `ssh xgs reboot` (resets the NPU). Wait 4 min. `ssh xgs 'grep -aE "mmcblk0p2|dp-boot|GIU pkt-echo|S99dp-fwd|login:|Kernel panic" /tmp/npucon.log | tail; sh /tmp/xgs-state.sh'`.
  **Pass:** `NPU: root=/dev/mmcblk0p2`, one `dp_fwd` pid, `restarts=0`, host autostart printed `NPU already runs persistent dp_fwd … binding it`, port1 lease, Pi ping 0 % loss.
- [ ] **Step 4 (Fail branches):** p2 up but no dp_fwd → `npucon.sh 'tail -30 /tmp/dp-boot.log'`, fix per Task 1.1, edit `/persistent/dp/dp-boot.sh` over mvmgmt0/npucon, re-run Step 2+3. p2 up, dp_fwd up, host does not bind → `kldunload/kldload` once; if that binds, note "ordering" and continue (Task 2.1 covers it). p2 never reaches login → nothing to do: the next `ssh xgs reboot` (or mains) boots p3 by construction; read `/tmp/npucon.log` for the panic text, record, fix p2 offline from p3.
- [ ] **Step 5:** Snapshot "Measured: first boot from p2 (one-shot)". Commit.

### Task 1.3: Warm reboots, one mains cycle, make p2 permanent

- [ ] **Step 1:** While still on the one-shot (each `ssh xgs reboot` would fall back to p3!), first make p2 permanent **only if Step 3 of Task 1.2 passed**: `fw_setenv bootcmd "$(fw_printenv -n bootcmd_emmc2)"; fw_setenv bootargs "$(fw_printenv -n bootargs_emmc2)"`, read back `mmc 0:2` + `root=/dev/mmcblk0p2`. Rollback command recorded in `docs/XGS126.md`: `fw_setenv bootcmd "$(fw_printenv -n bootcmd_emmc3)"; fw_setenv bootargs "$(fw_printenv -n bootargs_emmc3)"`.
- [ ] **Step 2:** Three `ssh xgs reboot` (warm) cycles: each ≤ 5 min to lease, `restarts=0`, `NPU: root=mmcblk0p2`. Log boot→lease seconds.
- [ ] **Step 3: Mains cycle** (smart plug if present, else ask the user once: "Bitte jetzt Netzstecker für 10 s ziehen"): same criteria. This is the only real power-cut proof before Phase 4.
- [ ] **Step 4:** `npu/stick/autostart.sh`: `wait_dp` budget 120 s; volatile branch only behind `AUTO_DP_FALLBACK=1` (default off). Push, commit. README status row → "Measured: dp_fwd persistent in NPU slot p2 (S91 disabled, respawn), 3 warm + 1 mains". Local tag `v0.2.0`.

**Gate 1 pass:** Steps 2–3 green and Task 1.1 Step 4 respawn ≤ 10 s.

---

## Phase 2: Robustness (measured first, then the smallest fix)

Driver builds: `tools/crossbuild-ko.sh` → `build/if_agnic.ko`, `tools/elfsyms.py` all resolved, then `ssh xgs 'cat > /tmp/if_agnic.ko'` and `'cat > /mnt/xgs/if_agnic.ko'`.

### Task 2.0: Measure an NPU-only reboot under a live host (precondition for any self-heal)

*Unverified today*: whether the x86 host survives the NPU (a PCIe endpoint) rebooting underneath it, and whether BARs/cookie remain readable afterwards. Two variants, safest first; the second only if the first is clean.

- [ ] **Step 1 (driver unloaded):** `ssh xgs 'kldunload if_agnic'`, start `npucon.sh` reader, `ssh xgs 'sh /tmp/npucon.sh "reboot"'` (NPU reboots; Linux `reboot` on the NPU), wait 4 min (p2 boots dp_fwd), `ssh xgs 'pciconf -lv | grep -A2 708011ab; kldload /tmp/if_agnic.ko; sleep 8; sh /tmp/xgs-state.sh'`. **Pass:** host stayed up (uptime continuous), endpoint listed, attach reaches `datapath live`, lease after `dhclient port1`.
- [ ] **Step 2 (driver loaded, watching):** `ssh xgs 'sh /tmp/npucon.sh "reboot"'` with `if_agnic` loaded; every 10 s `ssh xgs 'sysctl -n dev.agnic.0.rx_frames; dmesg | tail -3'` for 4 min. **Record:** does the host stay responsive; do the CTRL cookie / `DEV_READY` reads change (0xffffffff = link dropped); any panic. Then `kldunload; kldload` → does it come back?
- [ ] **Step 3:** Snapshot both into `docs/XGS126.md`. **Decision rule:** if Step 1 passes and Step 2 leaves the host alive → Task 2.1 as written. If Step 2 hangs the host → Task 2.1's watchdog must `kldunload` **before** the NPU can reset (i.e. on first loss signal, unload immediately), and the "reboot-host" escalation becomes the default.

### Task 2.1: Port ifnets exist without the NPU; userland session watchdog on the measured reload path

Council decision: **no in-kernel reattach in v1.0** (Appendix B1). Two small changes instead:

**2.1a — ifnets before the NPU (driver).** Today `port1..portN` are created only after handshake + discovery; a dead or slow NPU leaves OPNsense without its assigned interfaces (headless box stuck at the console assignment prompt).
- [ ] **Step 1:** In `if_agnic.c` attach: resolve `nports` from `hw.agnic.nports` / SMBIOS table (126 → 14) **immediately**, create the pport ifnets with `LINK_STATE_DOWN` and `IFF_DRV_RUNNING` off, then continue the bounded bring-up in the intrhook; when discovery later reports a different count, log it, keep the already-created ifnets (never destroy), create extras. `mvmgmt0` likewise created at attach. Frames for a not-yet-live session are dropped with `tx_dropped++`.
- [ ] **Step 2:** Test: `kenv hw.agnic.datapath=0; kldload` → `ifconfig -l` lists `port1..port14 mvmgmt0` within 2 s, all `no carrier`; `kldunload`. Then normal load → carrier `active` after the session. CHANGES #13; commit.

**2.1b — positive NPU-restart detection (dp_fwd + driver).**
- [ ] **Step 3:** `forwarder.c` writes a 32-bit **instance id** (`getpid() ^ boot-time seconds`) at metadata offset 0x44 of every RX frame; `agnic_pport.c` stores it; new sysctl `dev.agnic.0.npu_instance` and `dev.agnic.0.npu_instance_changes` (increments when the id changes). Rebuild dp_fwd on the Pi, redeploy to `/persistent/dp` (Task 3.3 chunked copy), rebuild the driver. Test: `pkill dp_fwd` on the NPU → `npu_instance_changes` +1 within 10 s. CHANGES #14; commit.

**2.1c — userland watchdog `agnic_watch` (rc.d, host).**
- [ ] **Step 4:** `kit/host/rc.d/agnic_watch`: loop every 5 s: `alive` = (`session_state` — until 2.1a exports it, use: `rx_frames` or `rx_dbell_count` advanced in the last 30 s **or** `ping6 -c1 -W1000` to the NPU link-local succeeded) **and** `npu_instance` unchanged. Loss condition = 3 consecutive misses **or** an instance change. Action = the measured path: `kldunload if_agnic; sleep 2; kldload /boot/modules/if_agnic.ko; sleep 8; ifconfig mvmgmt0 inet6 -ifdisabled auto_linklocal up`, then for every port that had a lease: `dhclient portN`; log to `/var/log/agnic.log` with reason and duration; counters `reattach_ok/failed` in `/var/run/agnic_watch.state`. Cap: after 5 failed reattaches in 30 min, if `AGNIC_REBOOT_AFTER_S` (default 0 = off) is set, `shutdown -r now`. Never fires during the first 180 s after boot.
- [ ] **Step 5: Test — NPU reboot without touching the host** (`ssh xgs 'sh /tmp/npucon.sh reboot'`): within 3 min `/var/log/agnic.log` shows `loss: instance change → reattach ok (N s)`, port1 lease back, Pi ping 0 % loss. 5×. Then **20 reload cycles** (`for i in $(seq 20); do kldunload if_agnic; sleep 2; kldload /tmp/if_agnic.ko; sleep 15; done`): 0 storm lines, load < 1, `mvmgmt0 link ESTABLISHED` each time. Commit.

### Task 2.2: mvmgmt0 (pcinet) bulk robustness

- [ ] **Step 1:** `agnic_pcinet.c`: on bring-up always publish fresh ring pointers and complete a ready round (never reuse stale mailbox pointers); `dev.agnic.0.mvmgmt_resets`; add ring-full backpressure (drop with counter instead of stalling) — hypothesis for the ~19 MB stall, to be measured.
- [ ] **Step 2:** Test after each of 10 reloads: `ping6 -c20` 0 % loss **and** `ssh xgs 'ssh ... root@NPU "dd if=/dev/zero bs=1M count=30" | wc -c'` = `31457280`. If the transfer still stalls after two hypotheses, keep the chunked-copy rule and record "mvmgmt0 bulk: not fixed in v1.0" — Phase 3 does not depend on it.
- [ ] **Step 3:** CHANGES #15; commit.

**Gate 2 pass:** 2.0 measured; 2.1a/b/c tests green (5× NPU reboot self-heal ≤ 3 min, 20 reloads clean); 2.2 Step 2 or its documented fallback.

---

## Phase 3: Install kit and OPNsense bring-up

### Task 3.1: rc.d `agnic_npu` (non-blocking) and `agnicctl`

- [ ] **Step 1: `kit/host/rc.d/agnic_npu`** — `PROVIDE: agnic_npu`, `REQUIRE: FILESYSTEMS kld`, `BEFORE: netif`. `start`: ensure `if_agnic` is loaded; wait **at most `AGNIC_WAIT_DP` (default 30 s)** for `dev.agnic.0` to report the session up; on timeout **continue the boot** (ifnets already exist per 2.1a) and leave the rest to `agnic_watch`; never block longer; log `/var/log/agnic.log`. `stop`: no-op. Starts **no** dp_fwd. Config `/usr/local/etc/agnic/agnic.conf`: `AGNIC_NPU_KEY` (optional), `AGNIC_WAIT_DP=30`, `AGNIC_REBOOT_AFTER_S=0`, `AGNIC_DHCP_PORTS=""` (lab only).
- [ ] **Step 2: `kit/host/agnicctl`**: `status|counters|reattach|watch-log|npu-shell|npu-state|npu-log`.
- [ ] **Step 3:** Test on the live stick (copy to `/usr/local/etc/rc.d/`, `/usr/local/sbin/`): `service agnic_npu start` → `datapath up` in the log; `agnicctl counters`. Commit.

### Task 3.2: Unattended FreeBSD 15.1 lab install on the second USB stick (no curses), kit install, negative test

The live stick *is* the 15.1 memstick, so `bsdinstall script` installs unattended from it, offline (sets in `/usr/freebsd-dist`).

- [ ] **Step 0: Port budget.** Two USB ports only. With a hub on the front port: live stick + USB NIC on the hub, target stick rear; drive everything over SSH. Without a hub: live stick front, target rear, **no NIC** — drive Steps 1–2 over the Pi console (`ssh printscan "xgscon '…'"`), then after Step 3's first boot ask the user once to swap the front live stick for the USB NIC; Task 0.1's fixed IP then comes up on the installed system (`installerconfig` sets it).
- [ ] **Step 1: Target disk.** `ssh xgs 'camcontrol devlist; geom disk list | grep -E "Name|Mediasize"'` → the rear medium is the `daN` that is **not** the live stick (`da0`, carries `EFISYS`) — refuse if ambiguous.
- [ ] **Step 2: `kit/lab/installerconfig`** (FreeBSD unattended install file; `kit/lab/lab-install.sh` substitutes `daN` and the two SSH keys and runs `bsdinstall script /tmp/installerconfig` on the stick host):

```sh
PARTITIONS=daN
DISTRIBUTIONS="kernel.txz base.txz src.txz"
#!/bin/sh
sysrc hostname=xgs126-lab sshd_enable=YES ntpd_enable=YES
sysrc ifconfig_ure0="inet 192.168.2.250/24" ifconfig_axge0="inet 192.168.2.250/24" defaultrouter=192.168.2.1
echo 'nameserver 192.168.2.1' > /etc/resolv.conf
printf 'console="comconsole"\ncomconsole_speed="115200"\nautoboot_delay="5"\n' >> /boot/loader.conf
mkdir -p /root/.ssh && cat > /root/.ssh/authorized_keys <<EOF
@@MAC_KEY@@
@@PI_KEY@@
EOF
chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys
sed -i '' 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
printf 'xgs:al=root:tc=3wire.115200:\n' >> /etc/gettytab
sed -i '' 's|^ttyu0.*|ttyu0 "/usr/libexec/getty xgs" vt100 onifconsole secure|' /etc/ttys
```

Expected: ~10 min, ends with `Installation complete`.
- [ ] **Step 3: First boot of the new stick.** `ssh xgs reboot`; if the BIOS boots the live stick again, set the one-time boot with `efibootmgr -n` from the live stick first; if unsupported, ask the user once to pick the second stick in the BIOS boot menu (the only possible manual step). **Pass:** `ssh root@192.168.2.250 'uname -a; mount | grep " / "'` shows 15.1-RELEASE on `daNp2`; `xgscon 'id'` = root.
- [ ] **Step 4: Kit install on the lab system.** `git clone` the repo (USB NIC has internet), `make -C driver` (`/usr/src` installed), `sh kit/host/install.sh --npu-key build/mvmgt.x86` → `/boot/modules/if_agnic.ko`, `/boot/loader.conf.d/agnic.conf`, rc.d `agnic_npu` + `agnic_watch`, `agnicctl`; reboot. **Pass:** `agnicctl status` up, 8 ports `active`, `dhclient port1` lease, no manual step.
- [ ] **Step 5: Negative test (dead NPU).** Flip the NPU to p3 (stock, no dp_fwd) with the Task 1.3 rollback command and reboot: the host must boot to SSH with **no** console prompt, `port1..port14` present with `no carrier`, `agnic_watch` logging attempts; flip back to p2, reboot → ports back.
- [ ] **Step 6:** `docs/INSTALL.md` (new): FreeBSD path (tested), OPNsense path (same `install.sh` or the packages of Task 3.4; box-level test deferred, Appendix B8). Commit; local tag `v0.3.0-rc1`.

### Task 3.3: NPU installer with self-reverting one-shot, verify, rollback

**Files:** `kit/npu/npu-install.sh`, `kit/npu/npu-verify.sh`, `kit/npu/npu-rollback.sh`, `kit/npu/payload/` (`dp_fwd`, `dp-nmp-config.txt`, `npu-run-dp_fwd.sh`, `dp-boot.sh`, `S99dp-fwd`, `SHA256SUMS`), `kit/npu/lib.sh` (chunked copy).

- [ ] **Step 1: `lib.sh` chunked copy:** `npu_put <local> <remote>`: if remote sha256 already matches → skip; else `split -b 1m` locally, for each chunk `ssh … 'cat >> remote.part'` with per-chunk `sha256sum` verification and up to 5 retries, then `mv remote.part remote`, final sha check. Transport = mvmgmt0; fallback for control commands = `npucon.sh`.
- [ ] **Step 2: `npu-install.sh`** (host): preflight — `uname -r` = `4.14.207-10.22.03`; running slot from `/proc/cmdline`; standby = the *other* of {p2,p3}; **hard refusal** if the computed standby equals the running slot or if `--target` names the running slot; tools present; `/persistent` free ≥ 5 MB. Then: payload → `/persistent/dp` (chunked, sha), mount standby ro → must carry `/boot/Image`, `cn9131-*.dtb`, `/etc/init.d/rcS` and `S91xgsstartup` (a vendor slot), remount rw → install `S99dp-fwd`, rename `S91xgsstartup` → `K91xgsstartup`, remount ro, save `uboot-env-before-flip.txt`. With `--flip`: write the **one-shot self-reverting `bootcmd`** of Task 1.2 Step 2 for the standby slot; print the verify + make-permanent commands. Without `--flip`: stop after staging.
- [ ] **Step 3: `npu-verify.sh`**: after a reboot — `root=` is the standby, one `dp_fwd` pid, `restarts` = 0, `GIU pkt-echo is started`, host `npu_instance` non-zero, optional `--lease port1`; with `--make-permanent` writes the permanent `bootcmd`/`bootargs` for that slot **only if all checks passed**.
- [ ] **Step 4: `npu-rollback.sh`**: restores `bootcmd`/`bootargs` from `uboot-env-before-flip.txt` (env flip only; never touches slot contents) and reboots via host reboot. The one-shot design means an unverified flip reverts on its own at the next power cycle.
- [ ] **Step 5: Test on the lab box (currently p2 permanent):** `npu-rollback.sh` → p3 stock → `npu-install.sh --flip` (standby = p2 again; re-installs idempotently) → reboot → `npu-verify.sh --lease port1 --make-permanent` → p2 permanent. Twice. Never writes p3. Commit; local tag `v0.3.0`.

### Task 3.4: OPNsense port + plugin packages, built on the FreeBSD lab system

- [ ] **Step 1:** On the lab FreeBSD: `pkg install git`, shallow-clone `opnsense/ports` to `/usr/ports` and `opnsense/plugins` to `/usr/plugins`; copy in `opnsense/ports/net/agnic-kmod` and `opnsense/plugins/net/agnic`. The kmod port uses `USE_GITHUB` with tag `v0.3.0`; until the tag is pushed (user's go) build from a local tarball (`git archive` → `MASTER_SITES=file:///root/dist/`). `make makesum && make package` → `agnic-kmod-0.3.0.pkg`; plugin `make package` → `os-agnic-0.3.pkg` with `rc.d/agnic_npu`, `rc.d/agnic_watch`, `agnicctl`, `rc.loader.d/50-agnic` in `pkg-plist`.
- [ ] **Step 2:** `pkg add` both on the lab FreeBSD (use `-f` if the plugin's OPNsense metadata is refused; note it) → reboot → same pass criteria as Task 3.2 Step 4. The **OPNsense box-level test is deferred** (Appendix B8); the PR to opnsense/plugins gets it built in their CI.
- [ ] **Step 3:** `kit/release/make-release.sh`: assembles `xgs-npu-freebsd-v0.3.0.tar.gz` (`kit/`, `build/if_agnic.ko` for 15.1, `INSTALL.md`, `SHA256SUMS`) and the release text `docs/release/v0.3.0.md`; creating the GitHub release needs the user's go.

**Gate 3 pass:** 3.2 Steps 4–5 and 3.3 Step 5 green; 3.4 packages build; `docs/INSTALL.md` current; release tarball assembled.

---

## Phase 4: Port tests — Pi-hosted, session-independent

Test bed: Port1..Port8 → one switch on the home LAN; Pi `printscan` on it; one L2 domain → host uses one FIB per port (`net.fibs=9`), `setfib N` + `-B <port-ip>`; `net.link.ether.inet.log_arp_wrong_iface=0`. **This measures a multi-port NIC on a single segment, not routing** (README says so; routed tests = Appendix B6). Pi services: `tools/pi/iperf3-multi.service` (eight `iperf3 -s -p 520N`), `tools/pi/nginx-testfiles` (1 KB–2 MB files). All suites are started as **systemd units/timers on the Pi** (`tests/pi/*.service|timer`) and write JSONL to `printscan:~/xgs-tests/out/`; `tests/report.py` evaluates in any later session.

JSONL record: `{"ts":"2026-09-20T14:03:00Z","suite":"functional","port":1,"check":"dhcp","pass":true,"value":"12.4","unit":"s"}`.

### Task 4.1: Harness and functional suite
- [ ] **Step 1:** `tests/lib.sh` (`xgs()`, `port_ip`, `fib_setup`, `counters`, `emit`, `assert_*`), `tests/run.sh <suite> [--ports 1-8] [--duration S]`, `tests/report.py`, `tests/README.md`, `tests/pi/functional.service`.
- [ ] **Step 2:** `tests/functional.sh` per port: link active; lease ≤ 30 s; ICMP 20/20 to the Pi; TCP sanity ≥ 1 Mbit/s (`setfib N iperf3 -c 192.168.2.187 -p 520N -B $(port_ip N) -t 5`); UDP 1 000 pps ≤ 0.5 % loss; drop counters unchanged; `ping -s 1472 -D`. **Pass:** 8 × 7 green in the report. Commit with the report.

### Task 4.2: Performance matrix (baseline; tuning is v1.1)
- [ ] **Step 1:** `tests/perf.sh`: per port TCP ↑/↓ 30 s, UDP `-l 64 -b 0` (pps ceiling) and `-l 1400`, `ping -c 500 -i 0.01` p50/p99, CPU snapshot, `dev.agnic.0` deltas; then all-8 concurrent 60 s and 4↑+4↓. `docs/PERFORMANCE.md` = the matrix. Acceptance note (not a gate): aggregate ≥ 300 Mbit/s TCP, ≥ 50 kpps @64 B with < 0.1 % loss at 80 % rate, p99 < 2 ms unloaded; below that → Appendix B4 tuning, after v1.0.

### Task 4.4: Endurance 24 h — a day in a firewall's life (Pi timers)
- [ ] **Step 1: Load** (`tests/soak.sh` as `tests/pi/soak.service`): TCP bidirectional ports 1–4 at 40 % of the measured per-port ceiling; UDP 5 kpps @ 200 B ports 5–6; "office" mix ports 7–8 (`curl` 1 000 req/min mixed sizes against the Pi nginx, `dig` 50 qps at the FritzBox). Per-minute JSONL.
- [ ] **Step 2: Events** (`tests/soak-events.sh`, `tests/pi/soak-events.timer`): every 30 min flap a random port (+ re-DHCP); every 6 h `agnicctl reattach`; hour 12 **NPU reboot** (`npucon.sh reboot` via `ssh xgs`); hour 18 **host reboot**; hour 23 `kldunload/kldload`. Each event row records recovery time (all leases + Pi ping) — must be ≤ 3 min.
- [ ] **Step 3: Health watch** (`tests/watch.sh`, host cron every 60 s → `/var/log/agnic-watch.jsonl`, pulled by the Pi): `dev.agnic.0` counters, `vmstat -z | grep -E 'mbuf|cluster'` (flat ± 5 %), load, `dmesg | grep agnic0:` new lines, `dev.cpu.0.temperature`; NPU every 5 min: uptime, `free`, `pidof dp_fwd`, `restarts`.
- [ ] **Step 4: Pass:** 0 wedges; every event ≤ 3 min; TCP retransmits < 0.1 %; UDP loss < 0.5 %; drop deltas 0 in quiet minutes; mbuf flat; NPU `restarts` = 0 except scheduled; report `tests/out/<date>-soak-24h.md` + `docs/XGS126.md`.

### Task 4.5: Endurance 72 h — release qualification
- [ ] **Step 1:** Task 4.4 profile with the event schedule daily, plus hour 36 **mains cut (mandatory)** — smart plug if present, else the user is asked at a stated clock time — and hour 60 ten minutes `ifconfig port1-8 down`.
- [ ] **Step 2:** Pass = 4.4 criteria over 72 h. Local tag `v1.0.0-rc1`; README "72 h soak passed (single-segment NIC profile)".

**Gate 4 pass:** 4.1 green, 4.2 matrix committed, 4.4 + 4.5 pass.

---

## Phase 5: Publish (this is the v1.0 goal: GitHub release + upstream PRs; every outward step needs one go from the user)

- [ ] **5.1** `docs/upstream/PR-mamoru.md`: branch from `e4101698`, one commit per CHANGES entry (`git commit -s`), dp_fwd device-0 + counter export + instance id + `dp-boot.sh` under `npu-firmware/`; PR text with measured results and the DSA-device-number finding.
- [ ] **5.2** `docs/upstream/PR-opnsense.md` for `net/agnic-kmod` (ports) and `net/agnic` (plugins, tier 3); `README.md` status + "Tested on" (XGS 126, FreeBSD 15.1; OPNsense: packages build, box-level untested); `CHANGELOG.md`; local tag `v1.0.0`; release tarball + `.pkg` files via `kit/release/make-release.sh`.
- [ ] **5.3 The one go:** present to the user: push `main` + tags to `github`, create GitHub release `v1.0.0` with assets, open the two PRs (mamoru, opnsense). Execute only what the user confirms.

---

## Autonomy rules for the executing session

1. Lab XGS only, reachable as `xgs` (192.168.2.250); fallback `ssh printscan "xgscon '…'"`; if both fail for 15 min, write the state to `docs/XGS126.md` and stop with a clear message (mains cycle needed).
2. Before any NPU write (`/persistent`, standby slot, `fw_setenv`): print running slot, standby slot and the rollback command; refuse if running slot ≠ expected; never write the running slot.
3. One hypothesis at a time; every failed step gets a "Measured" paragraph; never stack fixes.
4. Commit after every task; never push, tag-push, release or open PRs without the user's explicit go.
5. A task exceeding 3× its expected duration is paused and reported.
6. The user is needed only for: the checklist (once), the two mains cycles (Gate 1, hour 36 of the 72 h run) unless a smart plug exists, possibly one BIOS boot-menu selection in Task 3.2 Step 3, and the single go in Phase 5 (push, release, PRs).

---

## Appendix A: Council review of plan v1 (2026-09-15) and what changed

Four voices: Architect (in-context), Skeptic, Pragmatist, Critic (fresh subagents, plan + measured facts only).

- **Consensus:** the flip rollback via U-Boot was unreachable (host in POST during `bootdelay`) and the recipe lacked `bootargs` → replaced by a **self-reverting one-shot `bootcmd`** (Critic) plus Task 2.0 measuring NPU-only reboot (Skeptic/Pragmatist). `dp_fwd` had **no supervisor** → respawn loop in `dp-boot.sh`, logs to `/tmp` (Pragmatist/Critic). Task 1.1 tested the wrong state (parked S91) → **S91 disabled on p2**, dp-boot owns the bring-up (Skeptic/Critic). Scope cut for v1.0 (all three): MACs, jumbo, SoC ports, perf tuning, routed tests, kernel watchdog, manual FreeBSD install → Appendix B.
- **Strongest dissent (Skeptic):** drop the in-kernel watchdog entirely, ship userland reattach on the measured reload path. **Adopted** for v1.0 (Task 2.1c); the kernel version is B1.
- **Critic's surprise, adopted:** OPNsense headless boot needs the port ifnets to exist without the NPU (2.1a) and a non-blocking rc.d (3.1); positive NPU-restart detection via a dp_fwd instance id (2.1b); installer must hard-refuse the running slot (3.3); "cold" boots were warm → a real mains cycle is now in Gate 1 and mandatory at hour 36.
- **Pragmatist's surprise, adopted:** fixed IP instead of DHCP discovery (0.1); chunked, sha-verified copies over mvmgmt0 (3.3); soak as Pi systemd units (Phase 4); OPNsense **nano image written by the live-stick host** instead of a curses installer (3.2).
- **Rejected:** Pragmatist's suggestion to do the first p2 boot as an NPU-only reboot with the driver unloaded — superseded by the one-shot bootcmd (no console needed) and folded into Task 2.0 as the measured precondition for self-heal.

## Appendix B: v1.1 backlog (not on the v1.0 path)

- **B1** In-kernel session watchdog + re-attach (design of plan v1 Task 2.1: callout + taskqueue, `session_state/session_gen` sysctls, keep ifnets, backoff); only after 2.0 shows the host survives an NPU reset with the driver loaded.
- **B2** Per-unit MAC derivation (FNV-1a of `smbios.system.serial`, `hw.agnic.mac_fixed`).
- **B3** Jumbo frames (`CC_PF_INIT` frame size, `MJUM9BYTES`, `hw.agnic.jumbo`) — changes a measured contract; per-port carrier from a dp_fwd link bitmap at metadata 0x40.
- **B4** Performance tuning: ring depth 1024, doorbell-driven RX with 50 ms poll safety net, TX doorbell batching, `dp_fwd -c 3`, NMP queue sizes.
- **B5** eth1–eth4 SoC ports (`DP_SOC_PORTS=1`, extra ppio ports, tags 0x01–0x04 → port11–14).
- **B6** Routed/firewall tests over two L2 segments (second switch or VLANs, `pf` NAT, 6 h split soak).
- **B7** Production profile without console autologin; hardened `install.sh` defaults.
- **B8** OPNsense 26.7 on the user's box (installer or nano image, `config.xml` seed, GUI assignment test, dead-NPU negative test on OPNsense) — explicitly deferred by the user on 2026-09-15: v1.0 ships the installable driver, not an OPNsense deployment.
