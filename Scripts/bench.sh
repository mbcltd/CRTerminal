#!/bin/bash
# Terminal-core throughput benchmarks (release build). Record in PERF.md.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run --package-path Packages/TerminalCore -c release TerminalBench
