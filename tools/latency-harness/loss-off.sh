#!/bin/bash
pfctl -q -a com.apple/beam.loss -F all 2>/dev/null || true
dnctl -q flush
echo "loss OFF"
