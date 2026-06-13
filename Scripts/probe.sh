#!/bin/bash
# Drive the built app end-to-end (launches via `open` — windows don't
# display when the binary runs bare) and print the probe's report.
# Usage:
#   Scripts/probe.sh typist [script] [wait-seconds]
#       Types [script] into the live shell through the real input path.
#       Pass real control chars, e.g. $'vim /etc/hosts\r:q\r'; 0x1F = 1s
#       pause. Report: /tmp/crterminal-probe.txt, frame: …-probe.png.
#   Scripts/probe.sh typist-capture [script] [wait-seconds]
#       Same, plus dumps all PTY bytes to /tmp/crterminal-bytes.bin.
#   Scripts/probe.sh jump [query]
#       Opens the ⌘K palette over two sessions, applies [query], snapshots
#       to /tmp/crterminal-jump.png, report: /tmp/crterminal-jump.txt.
set -euo pipefail

app=$(ls -d ~/Library/Developer/Xcode/DerivedData/CRTerminal-*/Build/Products/Debug/crterm.app 2>/dev/null | head -1)
[ -n "$app" ] || { echo "No Debug build found — run Scripts/build.sh first" >&2; exit 1; }

mode="${1:?usage: Scripts/probe.sh typist|typist-capture|jump [args]}"
case "$mode" in
  typist|typist-capture)
    envargs=(--env CRT_TYPIST=1 --env "CRT_TYPIST_WAIT=${3:-1}")
    [ -n "${2:-}" ] && envargs+=(--env "CRT_TYPIST_SCRIPT=$2")
    [ "$mode" = typist-capture ] && envargs+=(--env CRT_TYPIST_CAPTURE=1)
    rm -f /tmp/crterminal-probe.txt
    open -n -W "${envargs[@]}" "$app"
    cat /tmp/crterminal-probe.txt ;;
  jump)
    envargs=(--env CRT_JUMP_PROBE=1)
    [ -n "${2:-}" ] && envargs+=(--env "CRT_JUMP_QUERY=$2")
    rm -f /tmp/crterminal-jump.txt
    open -n -W "${envargs[@]}" "$app"
    cat /tmp/crterminal-jump.txt
    echo
    echo "panel: /tmp/crterminal-jump.png" ;;
  jump-live)
    # Like jump, but first types [setup] into session 1 (typist path) so the
    # palette is probed against a session with a live foreground command.
    # Keep [setup] short: typing starts at ~2s (50ms/byte) and the palette
    # snapshots at ~4s. Usage: Scripts/probe.sh jump-live [setup] [query]
    envargs=(--env CRT_JUMP_PROBE=1 --env CRT_TYPIST=1 --env CRT_TYPIST_WAIT=30)
    [ -n "${2:-}" ] && envargs+=(--env "CRT_TYPIST_SCRIPT=$2")
    [ -n "${3:-}" ] && envargs+=(--env "CRT_JUMP_QUERY=$3")
    rm -f /tmp/crterminal-jump.txt
    open -n -W "${envargs[@]}" "$app"
    cat /tmp/crterminal-jump.txt
    echo
    echo "panel: /tmp/crterminal-jump.png" ;;
  *)
    echo "usage: Scripts/probe.sh typist|typist-capture|jump [args]" >&2
    exit 64 ;;
esac
