#!/usr/bin/env bash
# Fix the hotplug gap in nvidia-egpu-lockclocks.
#
# Problem it solves: the unit was Type=oneshot with RemainAfterExit=yes, so if
# the eGPU was not on the bus when it ran (boot without the enclosure, or a
# Thunderbolt reconnect), it "succeeded" without pinning anything and systemd
# never ran it again when the GPU showed up later.
#
# After this: the unit can be started again any time, and a udev rule starts it
# automatically whenever the RTX 5070 Ti appears on the PCI bus.
#
# Run: sudo bash install-lockclocks.sh

set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "error: run with sudo" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }

say "rewriting /usr/local/sbin/nvidia-egpu-lockclocks"
cat > /usr/local/sbin/nvidia-egpu-lockclocks <<'EOF'
#!/usr/bin/env bash
# Pin the eGPU to a fixed graphics clock so it never leaves P0.
# The Thunderbolt link retrain that kills the GPU happens during the
# P8 -> P0 transition, so removing the transition removes the trigger.
set -u

for _ in $(seq 1 30); do
	nvidia-smi -L >/dev/null 2>&1 && break
	sleep 1
done

if ! nvidia-smi -L >/dev/null 2>&1; then
	echo "nvidia-egpu-lockclocks: no NVIDIA GPU present, nothing to pin"
	exit 0
fi

nvidia-smi -pm 1 || true

max=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | head -1)
if [[ -n ${max:-} ]]; then
	echo "nvidia-egpu-lockclocks: pinning graphics clock to ${max} MHz"
	nvidia-smi -lgc "${max},${max}" || true
else
	echo "nvidia-egpu-lockclocks: could not read max graphics clock" >&2
fi
EOF
chmod 755 /usr/local/sbin/nvidia-egpu-lockclocks

say "rewriting /etc/systemd/system/nvidia-egpu-lockclocks.service"
# No RemainAfterExit: the unit goes back to inactive when it finishes, so the
# udev trigger below can start it again on hotplug.
cat > /etc/systemd/system/nvidia-egpu-lockclocks.service <<'EOF'
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

say "installing udev rule for GPU attach"
cat > /etc/udev/rules.d/98-egpu-lockclocks.rules <<'EOF'
# Re-pin the clocks whenever the eGPU appears on the PCI bus (boot, hotplug,
# Thunderbolt reconnect).
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x2c05", TAG+="systemd", ENV{SYSTEMD_WANTS}+="nvidia-egpu-lockclocks.service"
EOF

say "reloading systemd + udev"
systemctl daemon-reload
systemctl enable nvidia-egpu-lockclocks.service
udevadm control --reload-rules

say "current state"
systemctl is-enabled nvidia-egpu-lockclocks.service

if lspci -d 10de:2c05 >/dev/null 2>&1; then
	say "eGPU is attached -- pinning now"
	systemctl restart nvidia-egpu-lockclocks.service
	nvidia-smi --query-gpu=name,clocks.gr,power.draw --format=csv,noheader || true
else
	say "eGPU is not attached right now -- it will be pinned automatically when you plug it in"
fi

cat <<'EOF'

==> Done.

Note: the service is oneshot, so `systemctl status` will show
"inactive (dead)" once it has finished. That is normal -- check the clock
with:  nvidia-smi --query-gpu=clocks.gr,power.draw --format=csv

EOF
