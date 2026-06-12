# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CRTerminal is a macOS terminal emulator (AppKit, Swift) intended to be high-performance and GPU accelerated, with optional retro CRT screen appearance — including pre-configured presets matching historic monitors and a degauss button. The project is currently a fresh Xcode app template; the terminal functionality described in README.md is not yet implemented.

See ARCHITECTURE.md for the detailed design (module layout, concurrency model, render pipeline, performance budgets) and the phased implementation plan. Follow it when implementing features, and update it when the design changes.

## Commands

Use the wrapper scripts in `Scripts/` — they are allowlisted in
`.claude/settings.json`, so they run without permission prompts (raw
`xcodebuild`/`open` variants each re-prompt). Run them from the repo root.

```sh
# Build the app (filters output, prints the built .app path; add `release`)
Scripts/build.sh

# Tests: core | rendering | app | ui | all (default = what CI runs)
Scripts/test.sh
Scripts/test.sh core CellTests/rgbColorRoundTrips     # one package test
Scripts/test.sh app CRTerminalTests/JumpSearchTests   # one app suite/test

# Core throughput benchmarks (always Release; debug parses ~20× slower)
Scripts/bench.sh

# Fuzz the terminal core (libFuzzer; needs a swift.org toolchain — Xcode's Swift
# lacks the fuzzer runtime. Pass libFuzzer args like -max_total_time=60.)
Scripts/fuzz.sh

# End-to-end probes against the Debug build (launched via `open` — windows
# don't display when the binary runs bare); each prints its report file.
# typist: types bytes into the live shell through the real input path,
# dumps the grid + input→present latency to /tmp/crterminal-probe.{txt,png}.
# Pass real control chars (e.g. $'vim /etc/hosts\r:q\r'); 0x1F = pause 1s.
# typist-capture: same, plus all PTY bytes to /tmp/crterminal-bytes.bin.
# jump: opens the ⌘K palette, applies a query, snapshots the panel.
Scripts/probe.sh typist $'echo hi\r' [wait-seconds]
Scripts/probe.sh jump [query]
```

Record performance numbers in PERF.md when they change materially.

CI (`.github/workflows/ci.yml`) runs package tests plus the app build and unit tests.

## Structure

- `Packages/TerminalCore/` — platform-independent emulation engine (parser, grid, cells, encoders). No AppKit/Metal imports allowed. Swift 6 language mode.
- `Packages/CRTRendering/` — Metal/CoreText rendering; depends on TerminalCore.
- `Packages/TerminalCoreFuzz/` — libFuzzer harness, built only via `Scripts/fuzz.sh` (it links libFuzzer's main, so it is deliberately not in the normal build or CI).
- `CRTerminal/` — app target: AppKit lifecycle, window, view, input plumbing. Fully programmatic UI (no XIBs; `Entry.swift` has the `@main` entry point). The target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- `CRTerminalTests/` — app-target unit tests using the Swift Testing framework (`import Testing`, `@Test`, `#expect(...)`), not XCTest.
- `CRTerminalUITests/` — UI tests using XCTest/XCUIApplication.

Bundle identifier prefix is `mbcltd.`. The app target picks up new source files automatically (`project.pbxproj` uses file-system-synchronized groups, objectVersion 77) — no pbxproj edit needed. Don't name a file `Main.swift`: the case-insensitive filesystem makes the compiler treat it as top-level code, which conflicts with `@main`.

Gotchas learned the hard way:
- App Sandbox is deliberately OFF (a terminal must exec the user's shell unrestricted) — don't re-enable it.
- The Metal surface renders directly via `TerminalView.renderFrame()` driven by session updates, NOT via `updateLayer`/`needsDisplay` (AppKit never invoked `updateLayer` for the custom CAMetalLayer; CAMetalLayer doesn't need AppKit's display cycle anyway).
- `setVertexBytes` caps at 4 KiB — per-cell instance arrays must use `makeBuffer`.
- `TIOCSWINSZ` is ENOTTY on the posix_openpt *master* on macOS — winsize ioctls must target the slave fd (PTYSession keeps one open). When winsize is zeroed, ncurses silently falls back to 80×24, which can mask the bug.
- The shell must be spawned login_tty-style: fork + setsid + `TIOCSCTTY` (PTYSession binds `fork` via `@_silgen_name`; Swift marks it unavailable). posix_spawn cannot acquire a controlling terminal — there is no file action for the ioctl, and on macOS `POSIX_SPAWN_SETSID` + opening the slave does NOT claim it — so the shell ran with TPGID 0: the line discipline ate ^C/^Z with no foreground pgrp to signal, and job control silently broke. Symptom check: `ps -o tpgid,tt -p $$` showing `TT = ??`.
- Bundled fonts must register via `CTFontManagerRegisterGraphicsFont` (in-process), never `CTFontManagerRegisterFontsForURL`: URL registration is a fontd XPC transaction, and racing it against the process's first font lookups (parallel tests do exactly this) wedges the font-registry connection — every later `CTFontCreateWithName` hangs forever at 0% CPU while fontd sits idle. Also, Geist Mono's ligatures live in a "Coding ligatures" stylistic set, not `liga`/`calt`; `GlyphAtlas.ligatureFont(for:)` enables them on the shaping font.
