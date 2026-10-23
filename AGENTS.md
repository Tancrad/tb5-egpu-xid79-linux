# Repo notes for agents

This repository documents one machine's workaround for a Thunderbolt eGPU
falling off the PCIe bus (Xid 79). Read `README.md` first.

## Invariants

- The fix that matters is **pinning the GPU graphics clock**. Everything else
  in the README is supporting configuration that did not prevent the crash on
  its own.
- The 2.5 GT/s (Gen1 x4) tunnel is **not** the cause. It appears in both
  crashing and stable boots. Do not "fix" it as if it were the bug.
- The machine is Thunderbolt 4 on the host and Thunderbolt 5 in the enclosure,
  so Gen4 tunneling is not possible. Do not suggest a different cable for the
  link speed.

## Never commit unsanitized logs

Raw `journalctl` output from the source machine contains the LUKS UUID, GPU
UUID, hostname, MAC addresses and USB serials. Use `tools/sanitize-logs.py`
before adding any log file:

```bash
python3 tools/sanitize-logs.py raw.log logs/new-log.log
grep -E '[0-9a-f]{8}-[0-9a-f]{4}-|([0-9a-fA-F]{2}:){5}' logs/new-log.log
```

The sanitizer reads the hostname and username from the machine it runs on, or
from `SANITIZE_HOSTNAME` / `SANITIZE_USERNAME`.

## Tone

The write-up is deliberately framed as "n = 1, workaround, not a fix". Keep it
that way. Do not upgrade the claims to causation without new evidence.
