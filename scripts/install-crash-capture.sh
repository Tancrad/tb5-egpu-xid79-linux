#!/usr/bin/env bash
# egpu-crash-capture.sh — make the next eGPU crash survive on disk.
#
# The machine freezes/resets while the compositor is stuck on the dead GPU, so
# there is no way to keep a window (or opencode) open in that session. But the
# kernel keeps running, and these two changes make sure its last words are
# written to disk before you have to reset:
#
#   1. journald is flushed to disk every second instead of every 5 minutes
#      (that is why the last crash has no Xid 79 in it).
#   2. a tiny service mirrors the kernel log to /var/log/egpu-crash.log in
#      plain text, so it can be read even without journalctl.
#
# Optional: pass --ssh to also start sshd, so you can watch from a phone or
# another machine with `ssh <user>@<host>` + `journalctl -k -f`.
#
# Run: sudo bash install-crash-capture.sh [--ssh]

set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "error: run with sudo" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Flush the journal to disk at least once a second
# ---------------------------------------------------------------------------
say "journald: sync every second, no rate limit"
install -d -m 755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-crash-capture.conf <<'EOF'
# eGPU crash capture: don't lose the last 5 minutes of kernel messages on a
# hard reset, and don't drop the NVRM Xid flood.
[Journal]
SyncIntervalSec=1s
RateLimitIntervalSec=0
EOF

# ---------------------------------------------------------------------------
# 2. Plain-text mirror of the kernel log
# ---------------------------------------------------------------------------
say "installing /usr/local/sbin/egpu-crash-log"
cat > /usr/local/sbin/egpu-crash-log <<'EOF'
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
chmod 755 /usr/local/sbin/egpu-crash-log

cat > /etc/systemd/system/egpu-crash-log.service <<'EOF'
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

say "starting services"
systemctl daemon-reload
systemctl enable --now egpu-crash-log.service
systemctl restart systemd-journald

# ---------------------------------------------------------------------------
# 3. Optional: SSH so you can watch from another device
# ---------------------------------------------------------------------------
if [[ ${1:-} == --ssh ]]; then
	say "enabling sshd"
	systemctl enable --now sshd
fi

cat <<'EOF'

==> Done.

Next crash, the evidence is in one of these:

    cat /var/log/egpu-crash.log | tail -60
    journalctl -k -b -1 | tail -80

Live watching without a GUI (works while the compositor is frozen):

    journalctl -k -f

on a virtual terminal: Ctrl+Alt+F3 (internal display only, iGPU-driven),
or over SSH if you enabled it.

EOF
