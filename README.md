# Thunderbolt eGPU (RTX 5070 Ti) — Xid 79 on Linux

Notes from a single machine: a Blackwell eGPU in a Thunderbolt 5 enclosure on a
Thunderbolt 4 host. The GPU falls off the PCIe bus seconds after the desktop
starts using it. This documents the diagnosis, the reproducible trigger, and the
configuration that has been stable.

> **Status: workaround, not a fix.** This is one machine (n = 1) on one driver
> version. It is written up because the failure mode is confusing and the
> workaround is non-obvious. The underlying problem is a driver/firmware issue,
> tracked upstream in
> [NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979).

---

## TL;DR

| | |
|---|---|
| Symptom | `NVRM: Xid 79, GPU has fallen off the bus` 20–80 s after login, when the desktop first does GPU work (mouse movement, monitor settings) |
| Trigger | the GPU leaving its idle power state (P8 → P0) |
| Not the cause | the PCIe tunnel running at Gen1 x4 (present in both crashing and working boots) |
| Fix that worked | **pin the GPU graphics clock** so it never transitions, plus kernel cmdline params and PCI power pinning |
| Cost | ~40–45 W idle instead of ~10 W |
| Upstream | [NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) |

---

## Hardware and software

| | |
|---|---|
| Host | Framework Laptop 13 Pro (Intel Core Ultra Series 3), BIOS 03.02 |
| Host Thunderbolt | USB4 / Thunderbolt 4, four USB4 root ports (`00:07.0`–`00:07.3`, ports #21–#24) |
| Enclosure | Thunderbolt 5, Intel JHL9480 "Barlow Ridge Hub 80G" (`8086:5786`), NVM 64.81 |
| Enclosure retimer | NVM 28.82 |
| GPU | NVIDIA RTX 5070 Ti (`10de:2c05`), audio `10de:22e9` |
| OS | Arch Linux / Omarchy, kernel `7.2.8-9-omarchy` |
| Driver | `nvidia-open-dkms` 615.78.08 (open kernel modules) |
| Compositor | Hyprland / Aquamarine, started via `uwsm` |

Because the host is Thunderbolt 4 and the enclosure is Thunderbolt 5, the
enclosure runs in TB4 compatibility mode. The USB4 link itself is healthy at
40 Gb/s (2 lanes × 20 Gb/s).

---

## Symptoms

1. Boot with the eGPU attached, log in. Everything is fine for a few seconds.
2. As soon as the desktop does real GPU work — moving the mouse, opening a
   window, changing a monitor setting — the machine freezes.
3. If the eGPU drives external monitors, the cursor will not move onto them
   before the crash; the outputs appear enabled but do not update.
4. The kernel survives (it keeps logging), but the GUI session does not. A TTY
   or SSH session stays usable.

Sometimes the failure also tears down the Thunderbolt tunnel
(`thunderbolt 0-3: device disconnected`).

---

## What the crash looks like

Crashing boot, 26 seconds after boot:

```
21:15:17  NVRM: Xid (PCI:0000:2e:00): 79, GPU has fallen off the bus.
21:15:17  NVRM: Xid (PCI:0000:2e:00): 79, GPU has fallen off the bus.
21:15:17  NVRM: GPU 0000:2e:00.0: GPU has fallen off the bus.
21:15:17  NVRM: Xid (PCI:0000:2e:00): 154, GPU recovery action changed from 0x0 (None) to 0x1 (PF FLR)
21:15:18  pcieport 0000:00:07.1: AER: Multiple Uncorrectable (Non-Fatal) error message received from 0000:2e:00.0
```

Full kernel log: [`logs/crash-boot-kernel.log`](logs/crash-boot-kernel.log).

### AER is intermittent — do not trust its absence

An earlier crash of the same kind had **no AER message at all** and no
Thunderbolt disconnect:

```
20:33:38  NVRM: Xid (PCI:0000:2e:00): 79, GPU has fallen off the bus.
20:33:38  NVRM: Xid (PCI:0000:2e:00): 154, GPU recovery action 0x0 -> 0x1 (PF FLR)
```

Zero AER lines, zero `pciehp` link-down events, yet the GPU was gone. If you
only grep for AER you will conclude the wrong thing. Xid 79 means config-space
reads returned all-ones: the GPU stopped answering, whether or not the bridge
noticed.

There are also **correctable** physical-layer errors on the tunnel at boot:

```
21:14:51  pcieport 0000:00:07.1: AER: Correctable error message received from 0000:2e:00.0
21:14:51  pci 0000:2e:00.0: PCIe Bus Error: severity=Correctable, type=Physical Layer, (Receiver ID)
21:14:51  pci 0000:2e:00.0:    [ 0] RxErr                  (First)
```

That is a hint that the tunnel is marginal to begin with, which fits the low
link speed below.

---

## The link runs at Gen1 x4 — and it is not the cause

```
pci 0000:2e:00.0: 8.000 Gb/s available PCIe bandwidth, limited by
  2.5 GT/s PCIe x4 link at 0000:00:07.1
  (capable of 504.112 Gb/s with 32.0 GT/s PCIe x16 link)
```

What the chain actually looks like:

| Link | Speed | Source |
|---|---|---|
| USB4 cable link | 40 Gb/s (2 × 20) | `boltctl` |
| GPU ↔ enclosure switch | Gen4 x4 (16 GT/s) | `nvidia-smi` |
| Host tunnel (`00:07.1`) | Gen1 x4 (2.5 GT/s) | kernel / `lspci` |

So the GPU and the enclosure are fine. Only the Thunderbolt PCIe tunnel is
negotiated at Gen1. A TB4 host should tunnel PCIe at Gen3 x4 (32 Gb/s), so this
is 4× below spec — most likely the Barlow Ridge hub's TB4 fallback path.

Two things to note:

- **This is not what causes the crash.** The same Gen1 x4 tunnel is present in
  the 20-minute stable run below.
- **It does limit bandwidth.** 8 Gb/s raw is ~0.8 GB/s usable, and a compositor
  copying frames from the iGPU to the eGPU needs roughly 0.5 GB/s per 1080p60
  output. Three external monitors oversubscribe it; expect stutter.

Do not buy a cable because of the 2.5 GT/s number. It is negotiated, not a
signal-quality symptom you can fix at the cable.

---

## What did not help

These were all applied and verified active, and the crash still happened:

- `thunderbolt.host_reset=false` — necessary, but only stopped the tunnel being
  torn down at boot. **Note:** `thunderbolt` loads from the initramfs, so
  `options thunderbolt host_reset=false` in `/etc/modprobe.d/` is silently
  ignored. It has to go on the kernel command line.
- `pcie_aspm=off`
- `pcie_port_pm=off`
- `pcie_ports=native`
- `thunderbolt.clx=0`
- `NVreg_DynamicPowerManagement=0x00` (no runtime D3)
- `NVreg_EnableS0ixPowerManagement=0`
- `NVreg_EnableResizableBar=0`
- `power/control=on` via udev for the GPU, its audio function, and the TB switch

Each of these is still in the working configuration, but none of them prevents
the crash. With all five kernel parameters active the failure still happened
26-79 s after boot, depending on the run.

---

## What worked: pin the graphics clock

The GPU idles at ~195 MHz (P8) and boosts to ~2900 MHz (P0) the moment the
compositor starts rendering. That transition is what precedes the link failure.

Pinning the clock removes the transition:

```bash
nvidia-smi -pm 1
max=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits | head -1)
nvidia-smi -lgc "${max},${max}"
```

The A/B result on this machine:

| Boot | Pin | Duration | Result |
|---|---|---|---|
| 20:54 → 21:14 | yes | 20 min | stable, three external monitors, settings changes |
| 21:14 → 21:15 | no | 26 s | Xid 79 on first mouse movement |
| 21:28 → 22:09 | yes | 41 min | stable; HDMI settings changed, display orientation adjusted, three outputs |

The clock stays fixed at ~2910 MHz and the GPU draws ~43 W at idle instead of
~10 W. That is the trade.

This is consistent with the reports in upstream #979 where people with the same
GPU/enclosure combination can run compute workloads for hours but crash within
seconds of connecting a display.

---

## Step-by-step setup

### 1. Kernel command line

`thunderbolt` is in the initramfs, so use the kernel command line, not
`/etc/modprobe.d/`. On Limine (`limine-entry-tool`):

```bash
sudo install -d /etc/limine-entry-tool.d
sudo tee /etc/limine-entry-tool.d/egpu-stability.conf >/dev/null <<'EOF'
KERNEL_CMDLINE[default]+=" thunderbolt.host_reset=false pcie_aspm=off pcie_port_pm=off pcie_ports=native thunderbolt.clx=0"
EOF
sudo limine-update
```

Adjust for GRUB/systemd-boot if that is what you use.

### 2. NVIDIA module options

```bash
sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia_drm modeset=1
options nvidia NVreg_DynamicPowerManagement=0x00 NVreg_EnableS0ixPowerManagement=0 NVreg_EnableResizableBar=0
EOF
```

`nvidia` loads from the real root (not the initramfs), so these do apply.

### 3. Keep PCI power management away from the eGPU

```bash
sudo tee /etc/udev/rules.d/99-egpu-power.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x2c05", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x22e9", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x5786", ATTR{power/control}="on"
EOF
```

### 4. Pin the clock at boot and on hotplug

```bash
sudo tee /usr/local/sbin/nvidia-egpu-lockclocks >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u
for _ in $(seq 1 30); do
	nvidia-smi -L >/dev/null 2>&1 && break
	sleep 1
done
nvidia-smi -L >/dev/null 2>&1 || { echo "no NVIDIA GPU present"; exit 0; }
nvidia-smi -pm 1 || true
max=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | head -1)
[[ -n ${max:-} ]] && nvidia-smi -lgc "${max},${max}" || true
EOF
sudo chmod 755 /usr/local/sbin/nvidia-egpu-lockclocks
```

```bash
sudo tee /etc/systemd/system/nvidia-egpu-lockclocks.service >/dev/null <<'EOF'
[Unit]
Description=Pin the eGPU clocks to stop Thunderbolt link retrains
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-egpu-lockclocks

[Install]
WantedBy=multi-user.target
EOF
```

Deliberately **no** `RemainAfterExit=yes`: the unit must return to inactive so
the udev trigger below can start it again when the GPU appears later.

```bash
sudo tee /etc/udev/rules.d/98-egpu-lockclocks.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x2c05", TAG+="systemd", ENV{SYSTEMD_WANTS}+="nvidia-egpu-lockclocks.service"
EOF

sudo systemctl daemon-reload
sudo systemctl enable nvidia-egpu-lockclocks.service
sudo udevadm control --reload-rules
```

### 5. Reboot with the eGPU attached

---

## Verify

```bash
nvidia-smi --query-gpu=clocks.gr,power.draw --format=csv
# expect ~2900 MHz and ~43 W, not 195 MHz and ~10 W

lspci -vv -d 10de:2c05 | grep -E 'LnkCap:|LnkSta:'
lspci -vv -s 00:07.1    | grep -E 'LnkCap:|LnkSta:'
```

If the clock is still 195 MHz, the pin did not apply — check
`journalctl -u nvidia-egpu-lockclocks.service`.

`lspci -vv` needs root, and `00:07.1` only exists while the Thunderbolt tunnel
is up, so run those commands with the eGPU attached.

---

## Gotcha: the compositor will not see a GPU attached after login

Hyprland/Aquamarine enumerates DRM devices at startup. If you attach the eGPU
after logging in:

- the clocks are pinned automatically (udev), and
- the kernel sees the monitors (`/sys/class/drm/card1-DP-*` show `connected`),
- but `hyprctl monitors` shows only the internal display.

The session has to be restarted (log out/in or reboot) for the external outputs
to appear. This looks like "the eGPU does not work" but it is a separate
enumeration limitation.

---

## Capturing logs from a machine that freezes

Journald's default `SyncIntervalSec=5min` will lose the crash entirely — the
last seconds are never written to disk. Two changes fix that:

```bash
sudo install -d /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-crash-capture.conf >/dev/null <<'EOF'
[Journal]
SyncIntervalSec=1s
RateLimitIntervalSec=0
EOF
sudo systemctl restart systemd-journald
```

`RateLimitIntervalSec=0` matters too: the Xid flood gets rate-limited away
otherwise.

Then a plain-text mirror of the kernel log, so the last lines survive even if
journald does not. It uses `dmesg -w` and forces a write every 20 lines:

```bash
sudo tee /usr/local/sbin/egpu-crash-log >/dev/null <<'EOF'
#!/usr/bin/env bash
out=/var/log/egpu-crash.log
[[ -e $out ]] || : > "$out"
n=0
exec stdbuf -oL dmesg -w --time-format iso 2>/dev/null | while IFS= read -r line; do
	printf '%s\n' "$line" >> "$out"
	n=$((n + 1))
	(( n % 20 )) || sync -d "$out"
done
EOF
sudo chmod 755 /usr/local/sbin/egpu-crash-log

sudo tee /etc/systemd/system/egpu-crash-log.service >/dev/null <<'EOF'
[Unit]
Description=Mirror kernel log to /var/log/egpu-crash.log (eGPU crash capture)
After=local-fs.target

[Service]
ExecStart=/usr/local/sbin/egpu-crash-log
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now egpu-crash-log.service
```

After a crash:

```bash
journalctl -b -1 -k | grep -E 'Xid|fallen off|AER'
tail -60 /var/log/egpu-crash.log
```

---

## If it crashes again

In order:

1. **Check the pin is actually applied.**

   ```bash
   nvidia-smi --query-gpu=clocks.gr,power.draw --format=csv
   ```

   `195 MHz` means the pin is not active — that is the failure state.
   `~2900 MHz` means it is. At 195 MHz the next frame the compositor sends to
   the GPU is likely to kill it.

2. **Check whether the GPU was attached after login.** If so, the clocks are
   pinned but the compositor has no outputs for it; restart the session.

3. **Read the crash.**

   ```bash
   journalctl -b -1 -k | grep -E 'Xid|fallen off|AER'
   tail -60 /var/log/egpu-crash.log
   ```

4. **If the pin was applied and it still crashed**, the workaround has stopped
   working. Move to the open leads below.

## Open leads (untested)

- **GSP firmware.** Several eGPU reports say the *proprietary* driver with
  `options nvidia NVreg_EnableGpuFirmware=0` is stable where the open modules
  are not, and that the open modules ignore the option. This machine runs
  `nvidia-open-dkms`, so it cannot use it as-is. Worth testing if the clock pin
  stops working — and it would also restore boost clocks.
- **Kernel bugzilla 221319** — TB5 peripherals on USB4 hosts, GSP-related
  reboots.
- **Enclosure NVM update** for the TB4 fallback path. Would not fix the crash
  (the Gen1 tunnel is present in working boots) but may recover bandwidth.

## Caveats

- **n = 1.** One laptop, one enclosure, one driver version. Treat it as a
  starting point, not a universal fix.
- The clock pin costs idle power and prevents the GPU from boosting for
  games/CUDA. If you need boost clocks, this workaround is not for you.
- The Gen1 x4 tunnel is unresolved. A firmware update for the enclosure's
  TB4-compatibility path might change it; it did not affect stability here.
- The correct long-term fix belongs in the NVIDIA driver or the enclosure
  firmware. Please report your own data to upstream #979.

---

## Related

- [NVIDIA/open-gpu-kernel-modules#979 — Blackwell eGPU over Thunderbolt 5: hard lock / Xid 79](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
- [Arch Wiki — NVIDIA/Troubleshooting, Xid 79](https://wiki.archlinux.org/title/NVIDIA/Troubleshooting)

## License

MIT. Log excerpts are sanitized; UUIDs, MAC addresses, hostname, usernames and
serial numbers are replaced with placeholders.
