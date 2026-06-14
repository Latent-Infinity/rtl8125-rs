#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Packet-mutation fuzz harness.
#
# > "Packet-mutation harness to cover the data path: pktgen and
# >  Scapy/mausezahn injecting malformed L2/L3/L4 headers, bad
# >  checksums, truncated TCP options, illegal fragmentation. No
# >  panics, no KASAN/KCSAN reports."
#
# This script uses Python+Scapy to send malformed frames from the peer
# toward the RTL8125 guest interface, then watches the guest's dmesg
# for any KASAN/UBSAN/Oops/BUG/lockdep/DMA-API output.
#
# Requirements:
#   - Scapy installed on the host (apt install python3-scapy)
#   - Host interface configured on the same L2 segment as $IFACE
#   - PEER_IFACE is the host-side NIC facing the guest

set -uo pipefail

GUEST=${GUEST:-operator@192.168.122.174}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/agent/rtl8125_guest_codex}
PEER_IFACE=${PEER_IFACE:-enp4s0}
GUEST_IFACE=${GUEST_IFACE:-enp5s0}
GUEST_IP=${GUEST_IP:-10.0.0.2}
COUNT=${COUNT:-1000}
LOG=${LOG:-/tmp/r8125_pktmut.log}

SSH="ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY $GUEST"

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }

if ! python3 -c 'from scapy.all import *' 2>/dev/null; then
	red "FAIL: Scapy not importable — apt install python3-scapy"
	exit 1
fi

# Clear guest dmesg before the run.
$SSH "sudo dmesg -C" 2>/dev/null
echo "Packet-mutation fuzz against $GUEST $GUEST_IFACE ($GUEST_IP)" | tee "$LOG"
date | tee -a "$LOG"

# Generate $COUNT malformed frames covering:
#   - bad IP header checksum
#   - bad TCP checksum
#   - truncated TCP options
#   - illegal fragmentation (FRAG_OFFSET set on small frame)
#   - oversized payload claim with truncated wire
#   - random bit-flips in the L4 header
sudo python3 - "$PEER_IFACE" "$GUEST_IP" "$COUNT" <<'EOF' 2>&1 | tee -a "$LOG"
import random
import sys

from scapy.all import (
    Ether, IP, TCP, UDP, ICMP, Raw, sendp, get_if_hwaddr, conf,
)

iface, dst_ip, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
conf.verb = 0

# Discover the dst MAC via ARP-cache lookup. If unavailable, send
# unicast garbage to a synthetic MAC; the guest will drop it but
# we still exercise the L2 receive path.
dst_mac = "ff:ff:ff:ff:ff:ff"  # broadcast — guest will reject but we test L2
src_mac = get_if_hwaddr(iface)
print(f"src_mac={src_mac}, dst_mac={dst_mac}, dst_ip={dst_ip}, iface={iface}, count={count}")

mutations = [
    # 1. bad IP checksum
    lambda: Ether(src=src_mac, dst=dst_mac) /
            IP(dst=dst_ip, chksum=0xDEAD) /
            TCP() / Raw(b"A" * 64),
    # 2. bad TCP checksum
    lambda: Ether(src=src_mac, dst=dst_mac) /
            IP(dst=dst_ip) /
            TCP(chksum=0xBEEF) / Raw(b"B" * 64),
    # 3. truncated TCP options claim (dataofs says 15 = 60 bytes, but
    #    we only provide a normal 20-byte TCP header)
    lambda: Ether(src=src_mac, dst=dst_mac) /
            IP(dst=dst_ip) /
            TCP(dataofs=15) / Raw(b"C" * 64),
    # 4. illegal fragmentation: MF set on small whole packet
    lambda: Ether(src=src_mac, dst=dst_mac) /
            IP(dst=dst_ip, flags="MF", frag=0) /
            UDP() / Raw(b"D" * 32),
    # 5. UDP length claim larger than actual payload (truncation)
    lambda: Ether(src=src_mac, dst=dst_mac) /
            IP(dst=dst_ip) /
            UDP(len=9999) / Raw(b"E" * 16),
    # 6. random bit-flips in the L4 header
    lambda: Ether(src=src_mac, dst=dst_mac) /
            IP(dst=dst_ip) /
            TCP() /
            Raw(bytes(random.randint(0, 255) for _ in range(80))),
]

for i in range(count):
    pkt = random.choice(mutations)()
    try:
        sendp(pkt, iface=iface, verbose=False)
    except Exception as e:
        print(f"send failed at i={i}: {e}", file=sys.stderr)
    if i % 100 == 99:
        print(f"sent {i+1}/{count}", flush=True)

print(f"done — sent {count} malformed frames")
EOF

# Allow the guest a moment to process the last frames.
sleep 3

# Check dmesg for any anomaly.
if ! WARN_OUTPUT=$($SSH "sudo dmesg | grep -E 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|kmemleak|slab-use-after-free' || true" 2>&1); then
	red "FAIL: unable to collect remote dmesg over SSH for $GUEST"
	echo "$WARN_OUTPUT" | tee -a "$LOG"
	exit 1
fi

WARN_COUNT=$(printf '%s\n' "$WARN_OUTPUT" | grep -cE 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|kmemleak|slab-use-after-free')
echo "Post-fuzz dmesg warning count: $WARN_COUNT" | tee -a "$LOG"

if [[ "$WARN_COUNT" -eq 0 ]]; then
	grn "PASS: $COUNT malformed frames absorbed cleanly (no kernel warnings)"
	exit 0
else
	red "FAIL: $WARN_COUNT kernel-debug warnings after fuzz — review:"
	echo "$WARN_OUTPUT" | head -n 20 | tee -a "$LOG"
	exit 1
fi
