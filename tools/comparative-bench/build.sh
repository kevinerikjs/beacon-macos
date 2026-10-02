#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O flashboard.swift -o flashboard
swiftc -O watch.swift -o watch
echo "built flashboard and watch"
