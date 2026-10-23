#!/usr/bin/env bash
# Install the kernel cmdline, NVIDIA module options and udev power pinning for
# a Thunderbolt eGPU that drops off the PCIe bus (Xid 79).
#
# These settings are necessary but NOT sufficient on their own: the crash was
# only stopped by also pinning the GPU clocks. See install-lockclocks.sh.
#
# Run: sudo bash install-kernel-params.sh
#
# Assumes Limine with limine-entry-tool. For GRUB/systemd-boot, put the same
# parameters on the kernel command line with your bootloader's mechanism.

set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "error: run with sudo" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }

say "kernel command line: /etc/limine-entry-tool.d/egpu-stability.conf"
install -d -m 755 /etc/limine-entry-tool.d
cat > /etc/limine-entry-tool.d/egpu-stability.conf <<'EOF'
# Thunderbolt eGPU (RTX 5070 Ti) link stability.
#
# thunderbolt loads from the initramfs, so options in /etc/modprobe.d/ are not
# read at boot on this machine. Kernel parameters are applied regardless of
# when the module loads.
#
#   thunderbolt.host_reset=false  do not reset the USB4 host router (it tears
#                                 down the PCIe tunnel under the eGPU)
#   pcie_aspm=off                 no PCIe power saving on the tunnel
#   pcie_port_pm=off              keep PCIe root ports out of D3cold
#   pcie_ports=native             native PCIe port services (avoids D3cold hangs)
#   thunderbolt.clx=0             disable USB4 CLx low-power lane states
KERNEL_CMDLINE[default]+=" thunderbolt.host_reset=false pcie_aspm=off pcie_port_pm=off pcie_ports=native thunderbolt.clx=0"
EOF

say "NVIDIA module options: /etc/modprobe.d/nvidia.conf"
if [[ -e /etc/modprobe.d/nvidia.conf ]]; then
	cp -a /etc/modprobe.d/nvidia.conf /etc/modprobe.d/nvidia.conf.bak
fi
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1

# eGPU: stay out of runtime D3 and do not attempt BAR resizing (the resize
# fails inside a Thunderbolt bridge window).
options nvidia NVreg_DynamicPowerManagement=0x00 NVreg_EnableS0ixPowerManagement=0 NVreg_EnableResizableBar=0
EOF

say "udev: keep the eGPU out of PCIe runtime suspend"
cat > /etc/udev/rules.d/99-egpu-power.rules <<'EOF'
# Keep the Thunderbolt eGPU out of PCIe runtime suspend.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x2c05", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x22e9", ATTR{power/control}="on"
# TB5 PCIe switch inside the enclosure.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x5786", ATTR{power/control}="on"
EOF

say "applying"
udevadm control --reload-rules
if command -v limine-update >/dev/null 2>&1; then
	limine-update
else
	echo "limine-update not found -- update your bootloader entries manually" >&2
fi

cat <<'EOF'

==> Done. Reboot with the eGPU attached.

Note: this alone did not stop the crash here. Continue with
install-lockclocks.sh, which pins the GPU clock and is what made it stable.

EOF
