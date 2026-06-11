# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CRTerminal is a macOS terminal emulator (AppKit, Swift) intended to be high-performance and GPU accelerated, with optional retro CRT screen appearance — including pre-configured presets matching historic monitors and a degauss button. The project is currently a fresh Xcode app template; the terminal functionality described in README.md is not yet implemented.

See ARCHITECTURE.md for the detailed design (module layout, concurrency model, render pipeline, performance budgets) and the phased implementation plan. Follow it when implementing features, and update it when the design changes.

## Commands

Build and test from the command line with `xcodebuild` (scheme: `CRTerminal`):

```sh
# Build
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal build

# Run all tests
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal test

# Run a single unit test (Swift Testing)
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal test \
  -only-testing:CRTerminalTests/CRTerminalTests/example

# Skip the slow UI tests
xcodebuild -project CRTerminal.xcodeproj -scheme CRTerminal test \
  -skip-testing:CRTerminalUITests
```

## Structure

- `CRTerminal/` — app target. AppKit lifecycle (`AppDelegate`, `MainMenu.xib`), not SwiftUI.
- `CRTerminalTests/` — unit tests using the Swift Testing framework (`import Testing`, `@Test`, `#expect(...)`), not XCTest.
- `CRTerminalUITests/` — UI tests using XCTest/XCUIApplication.

Bundle identifier prefix is `mbcltd.`. New source files must be added via the Xcode project (`project.pbxproj` uses the modern file-system-synchronized groups, objectVersion 77, so files placed in the target folders are picked up automatically).
