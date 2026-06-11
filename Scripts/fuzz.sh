#!/bin/bash
# Build and run the TerminalCore libFuzzer harness.
# Usage: Scripts/fuzz.sh [extra libFuzzer args, e.g. -max_total_time=60]
#
# Requires a swift.org toolchain: Xcode's bundled Swift does not ship the
# libFuzzer runtime ("unsupported option '-sanitize=fuzzer'"). Install one from
# https://www.swift.org/install/macos/ and this script will pick it up, or set
# TOOLCHAINS explicitly.
set -euo pipefail

if [[ -z "${TOOLCHAINS:-}" ]]; then
    latest=$(ls -1 /Library/Developer/Toolchains 2>/dev/null | grep '^swift-.*\.xctoolchain$' | sort -V | tail -1 || true)
    if [[ -z "$latest" ]]; then
        echo "error: no swift.org toolchain found in /Library/Developer/Toolchains." >&2
        echo "Xcode's Swift cannot build libFuzzer targets; install a toolchain from" >&2
        echo "https://www.swift.org/install/macos/ (or set TOOLCHAINS yourself)." >&2
        exit 1
    fi
    TOOLCHAINS=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "/Library/Developer/Toolchains/$latest/Info.plist")
    export TOOLCHAINS
fi
echo "Using toolchain: $TOOLCHAINS"

cd "$(dirname "$0")/../Packages/TerminalCoreFuzz"

swift build -c release \
    -Xswiftc -sanitize=fuzzer,address \
    -Xswiftc -parse-as-library

CORPUS_DIR="../../.fuzz-corpus"
mkdir -p "$CORPUS_DIR"

exec ./.build/release/TerminalCoreFuzz "$CORPUS_DIR" "$@"
