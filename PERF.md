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

## Phase 5 — feature depth (2026-06-11)

Release build, Apple M3 Max, macOS 26.4.1. Phase 5 added wrap tracking +
link ids to the print hot path, resize reflow, and a shared-per-window
renderer (glyph atlas serialized with a lock across pane render threads).

Core throughput (`Scripts/bench.sh`) held within noise of Phase 3:

| Workload | Phase 3 | Phase 5 |
|---|---|---|
| scrolling-plain-ascii | 225 MB/s | 219 MB/s |
| wrapped-long-line | 355 MB/s | 345 MB/s |
| colored-text | 97 MB/s | 94 MB/s |
| alt-screen-cursor-addressing | 154 MB/s | 166 MB/s |
| utf8-mixed-wide | 67 MB/s | 70 MB/s |
| scroll-region | 212 MB/s | 199 MB/s |

End-to-end (typist probe, Release, VT220 preset): vim and a full tmux
attach/echo/detach round-trip behave; input→present median 5.49 ms
(single pane; the encode lock is uncontended with one pane and the pass
is sub-ms with several); idle assertion still passes (0 draws in 2 s
quiet, link paused); 88 MB footprint after the session.

Crashes found and fixed by the split-pane UI test, all in teardown or
sharing: CAMetalDisplayLink must be invalidated on its own thread (and
every RenderLoop entry point gated after invalidate), and the glyph
atlas needed the encode lock once two pane threads shared one renderer.

## Phase 4 — CRT effects (2026-06-11)

Release build, Apple M3 Max, macOS 26.4.1. Default preset DEC VT220 unless
noted; "Commodore 1702" is the heaviest preset (persistence + bloom + slot
mask + every composite artifact enabled).

| Metric | Value | Budget |
|---|---|---|
| Full CRT pipeline GPU time, 4K, Commodore 1702 | **best 1.20 ms, median 1.84 ms** | < 2 ms ✓ |
| Input→render latency, median (VT220 effects on) | 5.74 ms | ≤ Phase 3's 6.58 ms ✓ |
| Idle after output stops, effects on | 0 draws in 2 s, link paused | 0 CPU / 0 GPU ✓ |
| `time cat 100MB` in-terminal, effects on | 1.21 s ≈ 83 MB/s | no regression vs Phase 3 (1.26 s) ✓ |
| Memory after 100 MB cat (10k scrollback, 1440×768 px window) | 100 MB | < 100 MB — at the line |

Notes:
- GPU time measured by `EffectPipelineTests/fullPipelineFitsGPUBudgetAt4K`
  (sustained 30-frame loop; one-off submissions at idle GPU clocks read
  3–4× higher). Reusing the offscreen effect surfaces was the big win:
  freshly allocated multi-MB private textures cost ~5 ms of first-touch
  time on the GPU timeline per frame.
- Presets with long-persistence phosphor (IBM 5151, τ = 350 ms) keep the
  render loop alive ~2 s after output stops while trails decay, then the
  link pauses (verified: 58 decay frames in the quiet window, then paused).
  Presets with animated artifacts (1702: noise/hum/jitter) draw
  continuously while visible by design, throttled to 30 Hz on battery or
  in Low Power Mode.
- Honest gap: the persistence ping-pong pair is full-resolution rgba16F
  (8-bit storage would quantize faint trails into frozen ghosts), ~27 MB
  at 1440×768 — which puts the memory budget exactly at the line at this
  window size and over it for 4K windows on persistence presets. Lever if
  it matters: accumulate trails at half resolution as a separate additive
  layer instead of using the persistence output as the composite source.

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
number is already within ~2× of the kernel PTY ceiling). Ligatures
landed once Geist Mono shipped in the bundle (2026-06-12): only runs of
operator characters are shaped (prose/log lines skip shaping entirely)
and shaped runs are cached by text, so the steady-state cost is a
dictionary hit per operator run per frame.

## Phase 2 — real terminal (2026-06-11)

Same hardware/method. Latency held steady with the full Phase 2 feature set
(scrollback, wide chars, charsets, regions) in the hot path:

| Run | median | min | max |
|---|---|---|---|
| zsh echo | 5.83 ms | 5.41 ms | 12.39 ms |
| vim editing session | 5.70 ms | 3.48 ms | 11.75 ms |
