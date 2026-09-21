#!/bin/bash
# 2% packet loss on everything this Mac sends to the phone (TCP, UDP and ICMP so a ping can
# verify it). The anchor lives under com.apple/ because that is the only anchor path the
# default pf.conf evaluates. Run with sudo.
set -e
PHONE=${1:-192.168.18.45}; PLR=${2:-0.02}
dnctl pipe 1 config plr $PLR
echo "dummynet out quick proto { tcp udp icmp } from any to $PHONE pipe 1" | pfctl -q -a com.apple/beam.loss -f -
pfctl -E 2>/dev/null || true
echo "loss $PLR to $PHONE ON"; dnctl list | head -2
