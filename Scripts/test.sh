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
set -euo pipefail
cd "$(dirname "$0")/.."

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
    swift test --package-path Packages/TerminalCore ${2:+--filter "$2"} ;;
  rendering)
    # --no-parallel: these tests hit CoreText/Metal, and parallel font
    # lookups race the bundled-font registration's fontd XPC connection,
    # which wedges every later CTFontCreateWithName at 0% CPU (see CLAUDE.md).
    # Serial keeps the whole suite to a few seconds with no hang.
    swift test --package-path Packages/CRTRendering --no-parallel ${2:+--filter "$2"} ;;
  app)
    if [ -n "${2:-}" ]; then
      app_tests -skip-testing:CRTerminalUITests "-only-testing:$2"
    else
      app_tests -skip-testing:CRTerminalUITests
    fi ;;
  ui)
    app_tests -only-testing:CRTerminalUITests ;;
  all)
    "$0" core
    "$0" rendering
    "$0" app ;;
  *)
    echo "usage: Scripts/test.sh [core|rendering|app|ui|all] [filter]" >&2
    exit 64 ;;
esac
