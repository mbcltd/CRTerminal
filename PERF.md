# Performance log

## Find-bar live search (2026-06-22)

Release build, Apple M3 Max. The find bar re-scans the whole scrollback on
every keystroke to drive the `N / total` counter and the all-match highlight
(issue #44). `Scripts/bench.sh` now includes `search-*` over a full 10k-line
buffer (120 cols):

| Scan | Before | After |
|---|---|---|
| literal single char (44k hits) | 12.81 ms | 3.90 ms |
| literal word "fox" (11k hits) | 11.34 ms | 2.69 ms |
| regex `[0-9]+` (11k hits) | 85.37 ms | 73.44 ms |

The literal path (the overwhelmingly common case) is now allocation-free — it
scans the cells in place instead of flattening each line into scalar + column
arrays, ~3.3× faster. The regex path is dominated by `String` reconstruction +
`NSRegularExpression` and is largely unchanged. On top of this the live
(type-ahead) search is debounced ~90 ms in the find bar, so a scan runs at most
once per typing lull (Enter / next / prev / chip toggles still scan
immediately); this keeps typing smooth on Debug builds too, where each scan
costs ~10–20× the Release figures above.

---

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

## Phase R4 — session restoration: quit-latency (2026-06-14)

Debug build, Apple M3 Max, macOS 26.4. Measures the synchronous quit-time
save (`applicationWillTerminate` → `saveStateForTermination`), the concern
behind R4's "restoration adds no measurable quit delay". Reproduce with
`CRT_QUIT_LATENCY_PROBE=1`: 6 sessions each filled to the 10k-line scrollback
cap (~25 MB snapshot each, ~150 MB total), then two timed saves.

| Save | Time |
|---|---|
| warm (unchanged since last save — the realistic quit) | 0.03 ms |
| full (all 6 sessions dirty, 150 MB — pathological worst case) | 1.2 s |

The realistic quit is effectively free: the coalesced significant-change
debounce writes contents during the session, and a per-session
generation-skip elides any session whose grid hasn't changed since, so
quitting after the screen settles re-writes nothing.

The worst case (quit immediately after a heavy output burst in every session,
with no structural change to trip the debounce) is bounded by the cell-pack +
binary-plist write. Packing fills one preallocated buffer rather than
per-byte `Data.append`, which cut that worst case ~4× (4.9 s → 1.2 s for
150 MB). Load-side, a 128 MB-per-file cap rejects anything larger as corrupt,
so restored state can't blow the per-surface memory budget.
