#!/bin/zsh
# Double-click to start the trackpad bridge for the whiteboard's Tablet mode.
cd "$(dirname "$0")"
if [ ! -x ./trackpad-bridge ] || [ trackpad-bridge.swift -nt trackpad-bridge ]; then
  echo "Building trackpad bridge (first run only)…"
  swiftc -O -swift-version 5 trackpad-bridge.swift -o trackpad-bridge || { echo "Build failed."; read; exit 1; }
fi
./trackpad-bridge
