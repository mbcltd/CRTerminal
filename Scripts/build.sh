#!/bin/bash
# Build the app. Usage: Scripts/build.sh [release]
# Prints errors/warnings + result line only; exits nonzero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
config=Debug
[ "${1:-}" = "release" ] && config=Release
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal \
  -destination 'platform=macOS' -configuration "$config" build 2>&1 |
  grep -E "error:|warning: call|warning: capture|BUILD (SUCCEEDED|FAILED)"
# Product is crterm.app; the DerivedData folder keeps the project name.
{ ls -d ~/Library/Developer/Xcode/DerivedData/CRTerminal-*/Build/Products/"$config"/crterm.app 2>/dev/null || true; } | head -1
