#!/usr/bin/env python3
"""Sanitize kernel/journal excerpts before publishing them.

Replaces machine- and person-identifying values with placeholders:

    <UUID>      LUKS / filesystem / GPU UUIDs
    <MAC>       network and Bluetooth MAC addresses
    <HOSTNAME>  machine hostname
    <USER>      login name / home directory component
    <IP>        IPv4 addresses (skipped on firmware/version lines)
    <SERIAL>    USB / device serial numbers

Also drops noise lines that are irrelevant to the bug and tend to contain
third-party addresses (UFW block log) and NVIDIA assert spam.

Usage:
    sanitize-logs.py INPUT OUTPUT
"""

from __future__ import annotations

import getpass
import os
import re
import socket
import sys

HOSTNAME = os.environ.get("SANITIZE_HOSTNAME") or socket.gethostname().split(".")[0]
USERNAME = os.environ.get("SANITIZE_USERNAME") or getpass.getuser()

UUID = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I
)
MAC = re.compile(r"\b(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b")
IPV4 = re.compile(r"(?<![\w.-])(?:\d{1,3}\.){3}\d{1,3}(?![\w.-])")
SERIAL = re.compile(r"(?i)(SerialNumber:\s*)([0-9A-Za-z]{8,})")
HOST = re.compile(rf"\b{re.escape(HOSTNAME)}\b")
USER = re.compile(rf"\b{re.escape(USERNAME)}\b")

# Lines that are dropped entirely.
DROP = re.compile(r"UFW BLOCK|nvAssert|nvCheckOk|_issueRpc|_threadNode")

# Lines where dotted numbers are not addresses: firmware versions, and USB
# topology paths such as "usb 3-5.1.1.3" which would otherwise look like IPv4.
NOT_AN_IP = re.compile(
    r"(?i)microcode|firmware|revision|version|model name|bios"
    r"|usb|/devices/|xhci|hid-|input:|fseq"
)


def sanitize(line: str) -> str:
    line = UUID.sub("<UUID>", line)
    line = MAC.sub("<MAC>", line)
    line = SERIAL.sub(r"\1<SERIAL>", line)
    line = HOST.sub("<HOSTNAME>", line)
    line = USER.sub("<USER>", line)
    if not NOT_AN_IP.search(line):
        line = IPV4.sub("<IP>", line)
    return line


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    src, dst = sys.argv[1], sys.argv[2]
    kept = dropped = 0

    with open(src, encoding="utf-8", errors="replace") as fh, open(
        dst, "w", encoding="utf-8"
    ) as out:
        for line in fh:
            if DROP.search(line):
                dropped += 1
                continue
            out.write(sanitize(line))
            kept += 1

    print(f"{src} -> {dst}: {kept} lines kept, {dropped} dropped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
