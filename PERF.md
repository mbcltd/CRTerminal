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

## Phase 3 — performance (2026-06-11)

All numbers from a **Release** build (debug builds parse ~20× slower —
always use Release for performance work). Apple M3 Max, macOS 26.4.1.

Core throughput (`Scripts/bench.sh`, parser + screen model, no PTY/GPU):

| Workload | baseline | after Phase 3 |
|---|---|---|
| scrolling-plain-ascii | 31 MB/s | 225 MB/s |
| wrapped-long-line | 35 MB/s | 355 MB/s |
| colored-text | 42 MB/s | 97 MB/s |
| alt-screen-cursor-addressing | 37 MB/s | 154 MB/s |
| utf8-mixed-wide | 33 MB/s | 67 MB/s |
| scroll-region | 33 MB/s | 212 MB/s |

Gains: bulk printable-ASCII fast path (parser scan + chunked row writes),
CSI parameter buffer reuse, CoW-shared blank rows for scrolling.

End-to-end (typist probe, Release):

| Metric | Value | Budget |
|---|---|---|
| `time cat 100MB` in-terminal | **1.26 s ≈ 79 MB/s** | responsive throughout ✓ |
| Raw kernel PTY ceiling (same file) | 0.56 s ≈ 180 MB/s (~1 KiB/read) | — |
| Input→render latency, median | 6.58 ms | ≤ PTY floor + 1 frame @120 Hz ✓ |
| Idle after output stops | 0 draws, display link paused | 0 CPU / 0 GPU ✓ |
| Memory after 100 MB cat (full 10k scrollback) | 67 MB | < 100 MB ✓ |

Architecture changes: rendering moved to a dedicated CAMetalDisplayLink
thread (60–120 Hz ProMotion range) that pauses when idle; PTY reads moved
to a blocking poll/drain reader thread (dispatch-source wakeups were
~100k/100 MB); color emoji get their own premultiplied BGRA atlas.

Honest gaps vs the vtebench-class budget: core throughput is in the
hundreds of MB/s, not GB/s — the remaining costs are per-cell CoW row
writes and scroll memmoves; a ring-buffer grid and damage-row render
caching are the next levers if it ever matters in practice (the e2e
number is already within ~2× of the kernel PTY ceiling). Ligatures are
deferred: no ligature-capable monospace font is installed to verify
against (shaping-cache design is sketched in ARCHITECTURE.md).

## Phase 2 — real terminal (2026-06-11)

Same hardware/method. Latency held steady with the full Phase 2 feature set
(scrollback, wide chars, charsets, regions) in the hot path:

| Run | median | min | max |
|---|---|---|---|
| zsh echo | 5.83 ms | 5.41 ms | 12.39 ms |
| vim editing session | 5.70 ms | 3.48 ms | 11.75 ms |
