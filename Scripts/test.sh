#!/bin/bash
# Run tests. Exits nonzero on any failure.
# Usage:
#   Scripts/test.sh                  # everything CI runs (packages + app unit tests)
#   Scripts/test.sh core             # TerminalCore package
#   Scripts/test.sh core CellTests/rgbColorRoundTrips   # one package test
#   Scripts/test.sh rendering        # CRTRendering package
#   Scripts/test.sh app              # app-target unit tests (skips UI tests)
#   Scripts/test.sh app CRTerminalTests/JumpSearchTests # one suite or test
#   Scripts/test.sh ui               # UI tests (slow; not in the default run)
#
# Hang protection: CoreText/fontd can wedge so every CTFontCreateWithName
# blocks forever at 0% CPU (see CLAUDE.md). To stop that taking the whole run
# hostage, the actual test *run* (not the build — that legitimately varies) is
# watchdogged: if it overruns its budget we sample the wedged process to
# $HANG_LOG, kill our process tree, and retry. The bundled RenderTestSupport
# bootstrap is meant to prevent the wedge; this is the belt to that braces.
set -euo pipefail
set -m  # job control: each background job gets its own process group to kill
cd "$(dirname "$0")/.."

HANG_LOG="/tmp/crterminal-test-hang.txt"
MAX_ATTEMPTS=3
# Process names worth sampling when a run wedges (restricted to our own tree).
HELPER_RE='swiftpm-testing-helper|xctest|swift-test'

# Sample the wedged test helpers in our process group, then kill the tree.
# $1 is the backgrounded job's pid (== its process-group id under `set -m`).
capture_and_kill() {
  local pid=$1 p
  if command -v sample >/dev/null 2>&1; then
    {
      echo "=== test hang $(date) (pgid $pid) ==="
      for p in $(pgrep -g "$pid" 2>/dev/null || true); do
        if ps -o comm= -p "$p" 2>/dev/null | grep -Eq "$HELPER_RE"; then
          echo "--- sample $p ($(ps -o comm= -p "$p")) ---"
          sample "$p" 1 2>/dev/null || true
        fi
      done
    } >>"$HANG_LOG" 2>&1
    echo "   captured stacks → $HANG_LOG" >&2
  fi
  kill -TERM -- -"$pid" 2>/dev/null || true
  sleep 1
  kill -KILL -- -"$pid" 2>/dev/null || true
}

# Run "$@" with a wall-clock budget ($1 seconds). Returns the command's exit
# code, or 124 if it overran the budget and had to be killed.
run_with_timeout() {
  local budget=$1; shift
  "$@" &
  local pid=$! elapsed=0 rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$budget" ]; then
      echo "⏱  '$*' overran ${budget}s — likely the CoreText wedge" >&2
      capture_and_kill "$pid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# run_with_timeout plus auto-retry: a wedge is intermittent, so a fresh process
# almost always succeeds. Real test failures (any code but 124) return at once.
guard() {
  local budget=$1 attempt=1 rc; shift
  while :; do
    run_with_timeout "$budget" "$@" && return 0
    rc=$?
    [ "$rc" -ne 124 ] && return "$rc"
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      echo "✗ still wedging after $MAX_ATTEMPTS attempts; see $HANG_LOG" >&2
      return 124
    fi
    echo "↻ retrying ($attempt/$((MAX_ATTEMPTS - 1)))…" >&2
    attempt=$((attempt + 1))
  done
}

# Build test products unguarded (compile time varies), then run guarded with a
# tight budget so a wedged run is caught in seconds, not minutes.
package_tests() {
  local path=$1; shift
  swift build --package-path "$path" --build-tests
  guard 90 swift test --package-path "$path" --skip-build "$@"
}

app_tests() {
  local args=(-project CRTerminal.xcodeproj -scheme CRTerminal
              -destination 'platform=macOS')
  args+=("$@")
  # xcodebuild's exit code survives the pipe (pipefail); the grep keeps
  # failures and the verdict, dropping the build log noise.
  xcodebuild "${args[@]}" test 2>&1 |
    grep -E "error:|failed \(|Failing tests:|TEST (SUCCEEDED|FAILED)"
}

case "${1:-all}" in
  core)
    package_tests Packages/TerminalCore ${2:+--filter "$2"} ;;
  rendering)
    # --no-parallel: these tests hit CoreText/Metal, and parallel font
    # lookups race the bundled-font registration's fontd XPC connection,
    # which wedges every later CTFontCreateWithName at 0% CPU (see CLAUDE.md).
    # Serial keeps the whole suite to a few seconds; the guard above is the
    # backstop for when it wedges anyway.
    package_tests Packages/CRTRendering --no-parallel ${2:+--filter "$2"} ;;
  app)
    # xcodebuild rebuilds on `test`, so the budget covers build + run.
    if [ -n "${2:-}" ]; then
      guard 720 app_tests -skip-testing:CRTerminalUITests "-only-testing:$2"
    else
      guard 720 app_tests -skip-testing:CRTerminalUITests
    fi ;;
  ui)
    guard 720 app_tests -only-testing:CRTerminalUITests ;;
  all)
    "$0" core
    "$0" rendering
    "$0" app ;;
  *)
    echo "usage: Scripts/test.sh [core|rendering|app|ui|all] [filter]" >&2
    exit 64 ;;
esac
