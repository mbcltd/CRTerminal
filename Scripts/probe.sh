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
#   Scripts/probe.sh restore
#       Session restoration R1: types output, saves the session to disk,
#       reopens it restored, and checks the static text + cwd came back.
#       Report: /tmp/crterminal-restore.txt.
#   Scripts/probe.sh layout
#       Session restoration R2: builds two windows (one with 3 tabs incl a
#       2×2 split), saves layout + contents, rebuilds from disk, and checks
#       the tree, frames, contents, and cwds. Report: /tmp/crterminal-layout.txt.
set -euo pipefail

app=$(ls -d ~/Library/Developer/Xcode/DerivedData/CRTerminal-*/Build/Products/Debug/crterm.app 2>/dev/null | head -1)
[ -n "$app" ] || { echo "No Debug build found — run Scripts/build.sh first" >&2; exit 1; }

# The restoration probes (lifecycle, quit-latency) launch restorable windows
# and exit(0), so AppKit periodically flushes saved window state to disk.
# Left around, it gets replayed on the next `open -n` *on top of* the probe's
# fresh sessions, inflating the window/session count. Clear it before those
# probes so repeated runs are deterministic. (This is a probe-harness quirk of
# repeated `open -n` instances, not something normal launches hit.)
clear_saved_state() {
  rm -rf "$HOME/Library/Saved Application State/mbcltd.CRTerminal.savedState" 2>/dev/null || true
}

mode="${1:?usage: Scripts/probe.sh typist|typist-capture|jump [args]}"
case "$mode" in
  typist|typist-capture)
    envargs=(--env CRT_CLEAN_LAUNCH=1 --env CRT_TYPIST=1 --env "CRT_TYPIST_WAIT=${3:-1}")
    [ -n "${2:-}" ] && envargs+=(--env "CRT_TYPIST_SCRIPT=$2")
    [ "$mode" = typist-capture ] && envargs+=(--env CRT_TYPIST_CAPTURE=1)
    rm -f /tmp/crterminal-probe.txt
    open -n -W "${envargs[@]}" "$app"
    cat /tmp/crterminal-probe.txt ;;
  jump)
    envargs=(--env CRT_CLEAN_LAUNCH=1 --env CRT_JUMP_PROBE=1)
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
    envargs=(--env CRT_CLEAN_LAUNCH=1 --env CRT_JUMP_PROBE=1 --env CRT_TYPIST=1 --env CRT_TYPIST_WAIT=30)
    [ -n "${2:-}" ] && envargs+=(--env "CRT_TYPIST_SCRIPT=$2")
    [ -n "${3:-}" ] && envargs+=(--env "CRT_JUMP_QUERY=$3")
    rm -f /tmp/crterminal-jump.txt
    open -n -W "${envargs[@]}" "$app"
    cat /tmp/crterminal-jump.txt
    echo
    echo "panel: /tmp/crterminal-jump.png" ;;
  restore)
    rm -f /tmp/crterminal-restore.txt
    open -n -W --env CRT_RESTORE_PROBE=1 "$app"
    cat /tmp/crterminal-restore.txt ;;
  layout)
    rm -f /tmp/crterminal-layout.txt
    open -n -W --env CRT_LAYOUT_PROBE=1 "$app"
    cat /tmp/crterminal-layout.txt ;;
  lifecycle)
    # Cross-process R3 check: save → relaunch+restore (Always) → relaunch
    # clean (Never). Each phase is its own launch sharing the on-disk store.
    # Restore here is driven by our own layout file, so clear AppKit's saved
    # state before each launch — otherwise the save phase's flushed window
    # state replays as extra windows and the count checks misfire.
    rm -f /tmp/crterminal-lifecycle.txt /tmp/crterminal-lifecycle-manifest.json
    echo "--- save phase ---"
    clear_saved_state
    open -n -W --env CRT_LIFECYCLE_PROBE=save --env CRT_RESTORE_MODE=always "$app"
    cat /tmp/crterminal-lifecycle.txt
    echo "--- restore phase ---"
    clear_saved_state
    open -n -W --env CRT_LIFECYCLE_PROBE=restore --env CRT_RESTORE_MODE=always "$app"
    cat /tmp/crterminal-lifecycle.txt
    echo "--- never phase ---"
    clear_saved_state
    open -n -W --env CRT_LIFECYCLE_PROBE=verify-never --env CRT_RESTORE_MODE=never "$app"
    cat /tmp/crterminal-lifecycle.txt ;;
  quit-latency)
    # R4: time the synchronous quit-time save with several large sessions.
    clear_saved_state
    rm -f /tmp/crterminal-quit-latency.txt
    open -n -W --env CRT_QUIT_LATENCY_PROBE=1 --env CRT_RESTORE_MODE=system "$app"
    cat /tmp/crterminal-quit-latency.txt ;;
  *)
    echo "usage: Scripts/probe.sh typist|typist-capture|jump|jump-live|restore|layout|lifecycle|quit-latency [args]" >&2
    exit 64 ;;
esac
