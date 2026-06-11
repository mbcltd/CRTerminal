# Performance log

Measurements recorded per phase against the budgets in ARCHITECTURE.md.
Reproduce with the typist probe: build, then
`open -W --env CRT_TYPIST=1 <path-to-CRTerminal.app>` and read
`/tmp/crterminal-probe.txt` (grid dump, latency stats) and
`/tmp/crterminal-probe.png` (offscreen framebuffer render).

## Phase 1 — walking skeleton (2026-06-11)

Hardware: Apple M3 Max, macOS 26.4.1, 80×24 grid, SF Mono 13 pt @2x.

Input→render latency, measured from `TerminalView.send()` (the keystroke
entering the PTY) to the Metal command buffer for the echoed frame completing
on the GPU. 23 keystrokes typed at 50 ms intervals through the real input
path:

| Metric | Value |
|---|---|
| median | 4.31 ms |
| min | 2.37 ms |
| max | 57.67 ms (first frame: runtime shader compile + atlas warmup) |

Budget check: ≤ 1 added frame at 120 Hz (8.3 ms) — met at the median, with
the first-frame warmup as a known outlier. This number includes the full
round trip: PTY write → zsh echo → PTY read → parse → snapshot → encode →
GPU completion.

Not yet measured (Phase 3): vtebench throughput, idle-power assertion,
sustained-firehose behavior.

## Phase 2 — real terminal (2026-06-11)

Same hardware/method. Latency held steady with the full Phase 2 feature set
(scrollback, wide chars, charsets, regions) in the hot path:

| Run | median | min | max |
|---|---|---|---|
| zsh echo | 5.83 ms | 5.41 ms | 12.39 ms |
| vim editing session | 5.70 ms | 3.48 ms | 11.75 ms |
