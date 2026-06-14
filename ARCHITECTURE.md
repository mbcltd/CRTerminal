# CRTerminal Architecture

CRTerminal is a macOS terminal emulator with three design pillars, in priority order
when they conflict:

1. **Highly performant** — latency and throughput competitive with the best native
   terminals (Ghostty, Alacritty, Kitty). Performance is a feature the other two
   pillars sit on top of: the CRT effects are only fun if they never cost you a frame.
2. **Feature rich** — a real daily-driver terminal: full xterm-class VT emulation,
   truecolor, ligatures, emoji, IME, mouse protocols, scrollback search, tabs and
   splits, shell integration.
3. **Fun** — an authentic, configurable CRT simulation: phosphor glow and persistence,
   scanlines, shadow masks, curvature, presets modelled on historic monitors, and a
   degauss button that actually goes *thunk*.

The architecture keeps these concerns in separate layers so that "fun" is a pure
post-processing stage that can be toggled off, leaving a lean modern terminal.

---

## System overview

```
                ┌─────────────────────────── App target (AppKit) ───────────────────────────┐
                │                                                                            │
 keyboard/mouse │  NSWindow / TerminalView (NSView + NSTextInputClient)   Settings, Menus,  │
 ──────────────▶│        │ abstract key/mouse events                      Degauss button    │
                └────────┼───────────────────────────────────────────────────────┬──────────┘
                         ▼                                                        │ uniforms/presets
                  ┌─────────────┐  bytes   ┌──────────┐                           ▼
                  │ KeyEncoder  │─────────▶│   PTY    │                   ┌──────────────────┐
                  │ (core)      │  write   │ (fd+shell)│                  │  Renderer (Metal) │
                  └─────────────┘          └────┬─────┘                   │  cells ▶ texture  │
                                                │ read (IO queue)         │  ▶ CRT pipeline   │
                                                ▼                         │  ▶ CAMetalLayer   │
                                          ┌───────────┐   mutates        └────────▲─────────┘
                                          │ VT Parser │──────────┐                │ snapshot
                                          └───────────┘          ▼                │ (per frame)
                                                          ┌──────────────┐        │
                                                          │TerminalState │────────┘
                                                          │ grid, modes, │
                                                          │ scrollback   │
                                                          └──────────────┘
```

Data flows one way: input events are encoded to bytes and written to the PTY; PTY
output is parsed into mutations of `TerminalState`; the renderer reads immutable
snapshots of that state. The renderer never feeds back into the model, and the model
never knows it is being drawn on a fake CRT.

## Module layout

The repo hosts the Xcode app target plus local Swift packages. Everything that can be
platform-independent is, so the core builds and tests with `swift test` in seconds,
with no app host, and can be fuzzed from the command line.

| Module | Depends on | Contents |
|---|---|---|
| `TerminalCore` (SPM, no AppKit/Metal) | Foundation only | VT parser, `TerminalState`, grid/cells, scrollback, selection, key/mouse encoders, damage tracking |
| `CRTRendering` (SPM) | Metal, QuartzCore, CoreText, `TerminalCore` | glyph atlas, shaping cache, render passes, CRT effect pipeline, preset definitions |
| `CRTerminal` (app) | AppKit, both packages | windows, `TerminalView`, input plumbing, PTY/process management, settings UI, sounds |

Dependency direction is strict: `TerminalCore` ← `CRTRendering` ← app. The PTY lives
in the app target because process spawning is app policy; the parser does not care
where bytes come from (tests feed it byte arrays).

`TerminalCore` adopts Swift 6 language mode. Shared mutable state is confined as
described under Concurrency; everything else is value types.

---

## TerminalCore: emulation engine

### Parser

A table-driven state machine following Paul Williams' VT500-series parser
(states: ground, escape, CSI entry/param/intermediate, OSC string, DCS, etc.), with
UTF-8 decoding layered in front. Properties that matter:

- **Pure and synchronous.** `parser.feed(bytes)` produces actions applied to
  `TerminalState`. No I/O, no allocation on the hot path for plain text.
- **Resumable.** Input arrives in arbitrary chunk boundaries; the state machine
  carries partial sequences across chunks.
- **Total.** Malformed input never traps; unknown sequences are consumed and logged
  (a debug "unrecognised sequence" overlay aids conformance work). The parser is a
  fuzz target from day one.

Target emulation level: xterm-compatible VT220+ — the de-facto contract assumed by
ncurses/terminfo `xterm-256color`, plus modern extensions:
truecolor SGR, 256-color, underline styles and colors (SGR 4:x, 58), bracketed paste,
focus reporting, alternate screen, scroll regions, rectangular ops where cheap,
OSC 0/2 (title), OSC 4/10/11 (palette), OSC 8 (hyperlinks), OSC 52 (clipboard),
OSC 9/777 (notifications), mouse modes (X10/normal/button/any, SGR encoding),
`DECSCUSR` cursor shapes, XTGETTCAP/DA responses, and the kitty keyboard protocol as a
progressive enhancement.

### Screen model

- **Cell** — a fixed-size 16-byte struct: glyph reference (scalar, or index into a
  per-screen grapheme side table for multi-scalar clusters), packed fg/bg/underline
  color (palette index or RGB, tagged), attribute flags, and the OSC 8 hyperlink id
  (16 bits indexing a capped per-state URL table). Wide characters occupy a head
  cell plus a spacer tail cell.
- **Row** — contiguous `[Cell]`. The wrap bit lives in parallel `[Bool]` arrays
  alongside the screen and scrollback (rows stayed plain arrays for the CoW
  fast path); it is set when autowrap fires and drives reflow and
  rectangular-correct copy. Damage is generation-based, not per-row.
- **Grid** — active screen (primary + alternate) as CoW arrays of rows. Swift
  copy-on-write is load-bearing here: the renderer snapshots the grid by copying the
  array of row references (O(rows), microseconds); the parser's next mutation of a row
  triggers an isolated row copy. No frame ever observes a half-applied escape sequence.
- **Scrollback** — a ring buffer of evicted rows with a configurable cap (default
  10k lines). Rows are trimmed of trailing blanks on eviction to keep memory honest.
- **Damage tracking** — parser marks dirty rows plus a few cheap special cases
  (full scroll = texture shift, cursor-only change). The renderer draws nothing when
  damage is empty and no effect animation is running.

Resize performs reflow (rewrap soft-wrapped lines, exchanging rows with scrollback
and remapping the cursor and prompt marks) on the primary screen and simple
clip/extend on the alternate screen, matching user expectations from iTerm2/Ghostty.
Height-only changes pull rows back out of scrollback when growing and evict to
scrollback when shrinking.

### Inline images (graphics protocols)

Three protocols feed one image model. Transmitted images are stored by an
internal monotonic *serial* (the renderer's texture-cache key — re-transmitting
a kitty image reuses its client id but gets a fresh serial, so stale textures
fall out automatically). *Placements* record where an image shows, anchored to an
absolute row like `PromptMark`, so they scroll with the text and are evicted with
the scrollback; display extent is in cells, the source crop in pixels.

- **kitty graphics protocol** — APC strings (`ESC _ G <keys> ; <base64> ESC \`),
  dispatched from the parser's new `apcDispatch`. Transmit (direct and
  file/temp-file media), RGBA/RGB/PNG formats, chunked transmission, zlib
  (`o=z`, via `Compression`), display/put with source crop, cell extent,
  z-index and placement ids, delete, and query — with APC responses on the
  PTY-bound response channel.
- **sixel** — DCS strings (`ESC P … q … ESC \`), dispatched from `dcsDispatch`;
  a two-pass decoder (measure, then rasterize) handles palette select/define
  (RGB and HLS), RLE, and the transparency flag, producing RGBA.
- **iTerm2 inline images** — `OSC 1337 ; File=… : <base64>`; size tokens in
  cells, pixels, percent, or auto, with aspect preservation.

Pixel↔cell math and the `CSI 14/16 t` size reports need the device-pixel cell
size, which `TerminalCore` doesn't otherwise know; the app pushes it from the
renderer's metrics via `Terminal.setCellPixelSize`. Decoding to GPU textures
happens in `CRTRendering`'s `ImageTextureCache` (ImageIO for encoded formats,
direct upload for raw), kept per-pane on the `SurfaceContext`. Images are drawn
into the cell texture (under or over the glyphs by z-index), so they pass
through the CRT effect chain like everything else. The core stays free of
CoreGraphics: it reads pixel dimensions straight from PNG/JPEG/GIF/BMP headers.

### Input encoding

`KeyEncoder` and `MouseEncoder` are pure functions in `TerminalCore`:
(abstract key event, terminal mode flags) → bytes. The app translates `NSEvent` into
the abstract event; the encoder handles application cursor keys, modifyOtherKeys,
kitty protocol levels, and paste bracketing. Pure functions make the entire
key-encoding matrix unit-testable without a UI.

---

## PTY and process management

One `PTYSession` per terminal surface: `posix_openpt`/`forkpty`, spawn the user's
login shell (respecting `SHELL`, login-mode `argv[0]`, correct `TERM` and
`COLORTERM=truecolor`), propagate resizes via `TIOCSWINSZ`, reap with a process
lifetime monitor so exit status can be shown in-surface.

Reads use a `DispatchSourceRead` on a dedicated serial IO queue (userInteractive QoS).
**Flow control:** reads are bounded (e.g. 1 MiB per wakeup) and the parser runs with a
per-frame time budget; if a process firehoses output (`cat 100MB.txt`), we keep
consuming at full speed but only *render* coalesced snapshots at display rate, and we
let the kernel TTY buffer apply backpressure rather than buffering unboundedly in the
app. The UI thread is never involved in throughput.

Writes (keystrokes, paste) go through a small outbound queue with non-blocking writes,
so a stopped reader (`^S`) can't wedge the UI.

## Concurrency model

Three execution contexts, chosen for predictable latency over actor convenience:

| Context | Runs | Owns |
|---|---|---|
| IO queue (serial, per session) | PTY read, parser, state mutation | `TerminalState` writes |
| Render thread (per pane) | `CAMetalDisplayLink` callback, snapshot, encode, present | that pane's `SurfaceContext` (effect textures + phosphor clocks) |
| Main thread | AppKit events, IME, menus, settings | windows, sessions table |

The `TerminalRenderer` (pipelines + glyph atlas) is shared by every pane in a
window; cell-pass encoding is serialized with a lock because the atlas caches
mutate during rasterization. Per-pane state lives in each render loop's
`SurfaceContext`.

`TerminalState` is guarded by an unfair lock held only for mutation and for the CoW
snapshot — both microsecond-scale. The renderer is *pull-based*: each display-link
tick it takes a snapshot if damage exists (or an effect is animating) and draws;
otherwise it returns immediately and the display link is paused after a grace period.
Idle terminal = zero CPU, zero GPU.

Keystroke fast path: `NSEvent` → encode → write to PTY happens synchronously on the
main thread (writes are non-blocking), so added input latency is bounded by parse +
one frame. Target: keypress-to-photon within one display refresh of the theoretical
minimum.

---

## CRTRendering: drawing the terminal

### Text rendering

- **Glyph atlas.** Glyphs are rasterized with Core Text (`CTFontDrawGlyphs`) into
  texture atlases: an alpha-only atlas for regular glyphs (grayscale AA), an RGBA
  atlas for color emoji. Keyed by (font, glyph ID, style, subpixel-offset bucket),
  LRU-evicted. Atlas pages are allocated on demand; a font-size change flushes.
  Box Drawing (U+2500–257F) and Block Elements (U+2580–259F) never come from the
  font: `BoxDrawing` synthesizes them from exact cell geometry, pixel-snapped, so
  adjacent cells tile seamlessly (font glyphs don't fill the rounded-up cell and
  fallback fonts have foreign metrics, both of which leave background seams).
- **Shaping.** The fast path maps one cell → one glyph via the font's cmap, no shaping.
  When ligatures are enabled (a global setting, default on), only maximal same-style runs of
  *operator characters* (`=<>!&|:+-*/~%?.^#_`) are shaped with Core Text, so prose and
  log output never pay for shaping; results are cached by run text — `=>` costs one
  CTLine, then it's a dictionary hit. Runs split at a block cursor (its cell must keep
  its own glyph to invert cleanly) and on any fg/bg/attribute change; shaping that
  drags in a fallback font bails to the per-cell path. Font fallback (emoji, CJK,
  symbols) uses CTFontCreateForString with a per-codepoint fallback cache.
- **Bundled fonts.** Geist Mono (Regular/Bold/Italic/BoldItalic) and Departure Mono
  ship inside CRTRendering's resources (both SIL OFL 1.1; license texts sit beside the
  files) and are registered with process scope at launch. Geist Mono is the fixed
  terminal font (only its size is configurable); it is ligature-capable, which is
  what made the shaping path verifiable.
- **Draw.** Three instanced draws into an offscreen `terminalTexture`:
  background quads, glyph quads, then decorations (cursor, selection, underlines,
  IME marked-text). A full screen of cells is two-digit-thousands of instances —
  trivial for any Apple GPU at 120 Hz.

### CRT effect pipeline (the fun part)

The terminal image is composited through an effect chain, every stage of which is
skippable. With effects off, `terminalTexture` is drawn straight to the drawable and
CRTerminal behaves like a lean modern terminal.

```
terminalTexture
   │
   ├─▶ 1. Persistence    blend with previous frame at phosphor decay rate
   │                     (slow-decay phosphors like P39 leave real trails)
   ├─▶ 2. Bloom          threshold ▶ downsample ▶ separable blur ▶ composite
   │                     (phosphor glow / halation)
   └─▶ 3. Composite      single fragment shader applying, in order:
            barrel distortion + corner rounding (curvature)
            shadow mask / aperture grille / slot mask pattern
            scanlines (beam profile, not naive dark lines)
            convergence error + chromatic aberration
            noise, hum-bar flicker, interlace jitter (subtle, optional)
            vignette + glass reflection
   └─▶ 4. Bezel          optional monitor-bezel art composited around the screen
```

Design rules for the pipeline:

- **Simulation-grounded parameters.** Presets specify physical-ish values — phosphor
  chromaticity and decay time, mask pitch, beam width — not shader magic numbers, so
  presets read like spec sheets of real monitors.
- **Animated effects opt into frames.** Persistence, noise and flicker need continuous
  redraw; the render loop runs only while such an effect is active and visible, drops
  to damage-driven when the image has fully decayed, and degrades politely on battery
  (reduced noise framerate) — fun must not show up in Activity Monitor.
- **Degauss.** The titlebar/toolbar degauss button fires a ~1.5 s animation
  (electromagnetic wobble, hue swirl collapsing from the edges) with the authentic
  *thunk-hummmm* sample. Purely a uniform-driven effect in the composite pass.
  Optionally (off by default), the screen accumulates subtle corner "magnetisation"
  over long sessions, giving you a reason to press it.

### Presets

A preset is a declarative JSON document in the bundle (user presets in Application
Support): identity (name, year, blurb), phosphor, geometry, mask, bloom, artifacts,
bezel asset, suggested font and palette. A preset's `appearance` (dark/light) picks
the terminal color scheme; a preset may instead carry an explicit `colors` palette
(background, foreground, selection, the 16 ANSI hues — omitted slots fall back to
xterm) that overrides the appearance-derived scheme, and an optional `bottomBar`
(thickness + colour) that draws a thick stripe along the pane's bottom edge (a
CALayer above the Metal surface, like the bell flash). Launch set, chosen to span
the design space:

- **IBM 5151** — green P39 phosphor, heavy persistence, no mask (monochrome)
- **DEC VT220** — white or amber, fast phosphor, gentle curvature
- **Amdek 310A** — amber classic
- **Commodore 1702** — composite color, strong mask and bleed
- **Dark / Light** — all effects disabled; the modern terminal, dark or light
- **Danger** — a crimson "you're in production" palette (custom `colors`) with a
  thick burgundy bottom warning stripe; effects off

The settings UI renders presets as a gallery with live previews (each preview is just
the same pipeline at thumbnail size).

---

## App layer

- **TerminalView** — an `NSView` hosting a `CAMetalLayer`, implementing
  `NSTextInputClient` for full IME support (marked text drawn by the decorations
  pass), first responder for keys, mouse handling (selection vs. reported mouse modes,
  word/line/rectangular selection, click-through URL opening with ⌘).
- **Surfaces, sessions, splits.** A window holds sessions (sidebar tabs), each a
  tree of split panes; each pane is a surface (view + session + renderer sharing
  the window's atlas). Native `NSWindow` tabbing is disallowed — it was replaced
  by the session sidebar below, which native tabs can't express.
- **Session sidebar** (per the GlassTerm design handoff, which replaced the
  earlier native-tabs decision): a 240 pt vertical rail listing the window's
  sessions as rich rows — phosphor-themed accent bar, icon chip, live title,
  running pulse (foreground pgid ≠ shell pid via `tcgetpgrp`), cwd/process meta
  line, git dirty badge — plus a hover detail card per row (path, branch + dirty
  count, status/uptime, last exit code from OSC 133 marks, process · pid, and
  focus/⌘N-jump hints). Metadata comes from cheap 1 Hz kernel probes (libproc);
  git runs async behind a short cache. Hidden sessions are occluded: their render
  loops pause and ignore pokes until revealed. ⌘1-9 jump to sessions (presets
  moved to ⌃⌘1-9); ⌘⇧[ / ⌘⇧] cycle. The design's top-tabs toggle and ⌘K palette
  were not adopted.
- **Per-session themes.** Presets apply per session, not per window: each
  `SessionTab` carries its own preset, panes pass it to the shared renderer per
  draw (the renderer's stored preset is only a fallback; phosphor history resets
  when a pane's preset changes, tracked on its `SurfaceContext`). Sidebar rows
  render in their own session's theme; the window chrome (titlebar cluster,
  sidebar rail) follows the active session. The titlebar/menu theme switchers
  re-theme only the active session and do not change the default. The global
  settings preset ("Default theme") is the one every new session and window
  starts from, and is changed only in Settings.
- **Titlebar controls** (same handoff): a trailing control cluster with a theme
  switcher — one chip showing a phosphor-colored dot plus the active preset name,
  opening a dropdown where each row is styled in its own preset's look with a
  live-pipeline thumbnail — and the degauss button, drawn as a skeuomorphic
  graphite front-panel button (engraved label, pressed-in state) that only
  appears while the active preset has effects enabled.
- **Settings** — one global set of terminal settings (font, palette, preset, shell,
  scrollback), a live-preview preset gallery, and alerts, in a single scrolling pane
  written as declarative SwiftUI hosted in a settings window; settings persist via
  `UserDefaults`-backed codable models (`SettingsStore`).
- **Accessibility** — the grid is exposed through `NSAccessibility` as static text
  lines so VoiceOver can read the screen; effects never affect the accessibility tree.
- **Shell integration** — optional shipped shell snippets emit prompt marks
  (OSC 133), enabling jump-to-previous-prompt, command status ticks in the scrollbar
  region, and smarter selection.

## Testing strategy

- **Parser/state golden tests** (Swift Testing, in `TerminalCore`): feed byte
  sequences, assert grid contents/modes. Corpus seeded from esctest cases; vttest run
  as a manual conformance checklist per release.
- **Fuzzing**: libFuzzer target over `parser.feed` — must never crash or hang.
- **Encoder matrix tests**: every (key, modifier, mode) combination.
- **Render snapshot tests**: draw known grids through each preset offscreen, compare
  to reference images with a perceptual diff threshold.
- **Performance harness**: vtebench for throughput, a scripted keypress-to-present
  latency probe, and an idle-power assertion (no frames without damage). Numbers are
  recorded in-repo so regressions are diffable.

## Performance budgets

These are the contracts the design above exists to meet:

| Metric | Target |
|---|---|
| Keypress → present | ≤ 1 added frame at 120 Hz (parse+encode < 2 ms) |
| Throughput | vtebench within ~10% of Ghostty/Alacritty class |
| Idle | 0% CPU, 0 GPU encodes with no damage and effects quiescent |
| Full CRT pipeline | < 2 ms GPU per frame at 4K on Apple Silicon |
| Memory | < 100 MB per surface at 10k-line scrollback |

---

# Phased implementation plan

Each phase ends with something demonstrable and a hard exit criterion. Performance
work is not a phase — budgets above are enforced from Phase 1 — but each phase has a
primary focus.

### Phase 0 — Foundations
Restructure into the module layout above (`TerminalCore`, `CRTRendering` local
packages), CI running `swift test` + `xcodebuild` on GitHub Actions, fuzz target
scaffolding, replace the template XIB with a programmatic window.
**Exit:** packages build and test in CI; app launches to an empty Metal-backed window.

### Phase 1 — Walking skeleton: a live shell
PTY session running the login shell; parser handling UTF-8, C0 controls, and the core
CSI set (cursor movement, erase, basic SGR); fixed-size grid; Metal renderer with a
working glyph atlas (no ligatures); basic key encoding.
**Exit:** interactive zsh with colored `ls`, line editing, and scrolling output;
keypress latency measured and recorded.

### Phase 2 — A real terminal
Full VT500 state machine and mode set, alternate screen, scroll regions, truecolor,
wide chars + emoji (with fallback), non-reflow resize, scrollback + selection +
clipboard, mouse reporting, bracketed paste, OSC title/8/52, cursor styles.
**Exit:** vim, tmux, htop, fzf and midnight-commander all behave correctly; golden
test corpus in place; targeted esctest subset passing.

### Phase 3 — Performance and text quality
Damage-driven rendering tightened, scroll-shift fast path, ligatures + shaping cache,
color emoji atlas, ProMotion/120 Hz, flow-control hardening against firehose output,
Instruments passes, vtebench + latency harness wired into the repo.
**Exit:** all performance budgets met and recorded; `cat` of a 100 MB file stays
responsive throughout.

### Phase 4 — The CRT experience
Offscreen pipeline, persistence, bloom, composite shader (curvature, masks, scanlines,
aberration, noise), preset format + the launch preset set, preset gallery with live
preview, degauss button with animation and sound, bezel rendering, battery-aware
effect throttling.
**Exit:** 5 presets shipping; effects toggle cleanly; full pipeline within GPU budget;
idle-power assertion still passes with effects enabled but quiescent.

### Phase 5 — Feature depth
Tabs and split panes, global settings UI, scrollback search, URL/path
detection + OSC 8 links, shell integration (OSC 133 marks, prompt jumping), IME
polish, kitty keyboard protocol, resize reflow, notifications (OSC 9/777),
accessibility pass.
**Exit:** daily-drivable: a developer can replace their terminal with CRTerminal for a
week without falling back.

### Phase 6 — Ship
App icon, hardened runtime + notarization, Sparkle auto-update, crash reporting,
Homebrew cask, website/screenshots (the presets sell themselves), vttest/esctest
regression checklist, README rewrite.
**Exit:** signed, notarized 1.0 downloadable outside the App Store.

# Feature plan: tab alerts, dock badge, and progress

When a background tool rings BEL or posts a notification (Claude Code waiting for
input is the motivating case), the user should see it without watching the tab.
Design: a per-session *attention* state, set when a bell/notification arrives in a
session that is not focused (not the active tab, or window not key, or app not
active), cleared the moment that tab is selected. Surfaces, from quietest outward:
sidebar row badge → dock badge → user notification. A bell in the focused pane stays
sound-only. Activating the app does not clear attention; only viewing the tab does.
OSC `9;4` (ConEmu progress) joins the same pipeline so a tab can show task progress.

### Phase A — TerminalCore: OSC 9;4 progress
Parse `OSC 9;4;state;percent` (0 clear, 1 normal, 2 error, 3 indeterminate,
4 paused) into a `progress` field on `TerminalState`, instead of today's misparse as
a notification with body `"4;…"`. Clear stale progress on FTCS prompt start (OSC
133). Package tests for states, malformed payloads, clamping; fuzz run.
**Exit:** `Scripts/test.sh core` green; `printf '\e]9;4;1;50\a'` sets progress and a
new prompt clears it.

### Phase B — Attention model + sidebar bell badge
`TerminalView`'s existing `bellCount` diff gains an `onBell` callback wired like
`onNotification`; `SessionTab` tracks `unseenBells`/`lastBellAt`; controller sets it
when the session isn't focused, clears in `selectTab` and on window-became-key.
Sidebar rows render an amber bell dot (count if > 1) with the existing pulse
animation; hover card gets a "rang bell Nm ago" line.
**Exit:** bell in a background tab badges its row; selecting the tab clears it;
`SessionSidebarTests` cover set/clear rules.

### Phase C — Progress in the tab row
`refreshSessionMetadata` (1 s timer) reads `snapshot.progress`; rows draw a thin
progress bar along the bottom edge in the row's phosphor accent (amber for error,
shimmer for indeterminate) and append the percent to the meta line.
**Exit:** `Scripts/probe.sh typist` with an OSC 9;4 emitter shows the bar in the
sidebar screenshot.

### Phase D — Dock icon badge
App-level aggregation across all window controllers sums attention sessions into
`NSApp.dockTile.badgeLabel`; optional (settings-gated, default off) single
`requestUserAttention` bounce when a bell arrives while the app is inactive.
**Exit:** bells in two windows badge the dock with "2"; viewing each tab decrements.

### Phase E — BEL notifications with click-to-jump
`NotificationPoster` posts for plain BEL when the app is inactive, titled with the
session's process name, debounced ~2 s per session. A
`UNUserNotificationCenterDelegate` carries the session UUID in `userInfo`; clicking
activates the app, fronts the owning window (reuse the ⌘K cross-window session
lookup), and selects the tab. OSC 9/777 notifications gain the same jump.
**Exit:** a bell from a hidden window's session posts one notification per burst and
clicking it lands on that session.

### Phase F — Alert settings + visual bell
Global "Alerts" settings group (UserDefaults-backed, `SettingsStore` pattern): bell
sound, sidebar badges, dock badge, bounce, notifications, visual bell. Visual bell =
~150 ms phosphor-tinted overlay flash on the bell pane (a CALayer above the Metal
surface, not a pipeline uniform, so it works on every preset including museum off);
deliberately fires in the focused tab too, where it is the only visible cue.
**Exit:** every alert surface can be disabled; visual bell flashes with sound off.

## Risks and mitigations

- **Resize reflow** is notoriously fiddly → ship non-reflow resize early (Phase 2),
  build reflow on the wrap-bit data model later (Phase 5).
- **IME edge cases** (marked text + alternate screen + scroll) → `NSTextInputClient`
  from the first view implementation, not retrofitted.
- **Effect power draw** → animated effects gated by visibility/battery from the first
  shader, enforced by the idle-power test.
- **Scope creep on protocols** (sixel, kitty graphics) → now implemented (see
  "Inline images" below); the offscreen-texture design left the room the original
  plan anticipated. Animation frames and shared-memory transmission remain out of
  scope.
- **Period fonts/bezel art licensing** → only bundle assets with clear licenses;
  presets may *suggest* fonts without bundling them.
