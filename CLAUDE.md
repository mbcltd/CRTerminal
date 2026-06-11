# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CRTerminal is a macOS terminal emulator (AppKit, Swift) intended to be high-performance and GPU accelerated, with optional retro CRT screen appearance — including pre-configured presets matching historic monitors and a degauss button. The project is currently a fresh Xcode app template; the terminal functionality described in README.md is not yet implemented.

See ARCHITECTURE.md for the detailed design (module layout, concurrency model, render pipeline, performance budgets) and the phased implementation plan. Follow it when implementing features, and update it when the design changes.

## Commands

Most code lives in local Swift packages — prefer `swift test` there (fast, no app host):

```sh
# Package tests (the usual dev loop)
swift test --package-path Packages/TerminalCore
swift test --package-path Packages/CRTRendering

# Run a single package test
swift test --package-path Packages/TerminalCore --filter CellTests/rgbColorRoundTrips

# Build the app
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal -destination 'platform=macOS' build

# App-target tests (skipping slow UI tests, as CI does)
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal -destination 'platform=macOS' \
  -skip-testing:CRTerminalUITests test

# Core throughput benchmarks (always Release; debug parses ~20× slower)
Scripts/bench.sh

# Fuzz the terminal core (libFuzzer; needs a swift.org toolchain — Xcode's Swift
# lacks the fuzzer runtime. Pass libFuzzer args like -max_total_time=60.)
Scripts/fuzz.sh

# End-to-end probe: types a command into the live shell, dumps the grid,
# measures input→render latency, writes /tmp/crterminal-probe.{txt,png}
# CRT_TYPIST_SCRIPT overrides the typed bytes (real control chars, e.g.
# $'vim /etc/hosts\r:q\r'; 0x1F = pause 1s — NUL would truncate the env var);
# CRT_TYPIST_WAIT = settle seconds; CRT_TYPIST_CAPTURE=1 dumps all PTY bytes
# to /tmp/crterminal-bytes.bin for replay debugging.
# Must launch via `open` — windows don't display when the binary runs bare.
open -W --env CRT_TYPIST=1 <DerivedData>/Build/Products/Debug/CRTerminal.app
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
