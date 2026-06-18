---
name: bump-version
description: Bump the marketing version (marketing_version.txt) when shipping a feature, fix, or breaking change. Use after landing user-facing work, when asked to "bump the version", "cut a release version", or "release" CRTerminal. Applies the MAJOR.MINOR.PATCH conventions below.
---

# Bump the marketing version

The shipping version of CRTerminal lives in **`marketing_version.txt`** at the repo
root — a single `MAJOR.MINOR.PATCH` line (e.g. `1.0.1`). This is the canonical
source of truth:

- `Scripts/release.sh` reads it into `CFBundleShortVersionString` and the Sparkle
  appcast `<title>` / `<sparkle:shortVersionString>`.
- `.github/workflows/ci.yml` reads it into `$VERSION`.
- The `MARKETING_VERSION` values in `CRTerminal.xcodeproj/project.pbxproj` are
  **overridden at build time** by the release script — do **not** edit them; edit
  only `marketing_version.txt`.

The build number (`CFBundleVersion`) is separate: it's the monotonic CI run number
(or local git commit count), and is what Sparkle compares to decide "is there an
update?". You never touch the build number here.

## When to bump, and which number

Bump on **any feature change or user-facing change** that will ship. Choose the
component using these conventions (this is an end-user macOS app, so "API" means
the user-facing surface: features, UI, settings, keybindings, behavior).

### MAJOR (`X.0.0`) — breaking or identity-defining changes
Reset MINOR and PATCH to 0. Bump MAJOR when:
- A change removes or fundamentally redefines existing behavior users rely on
  (e.g. a settings/preset format change that invalidates saved state, dropping a
  supported macOS version, removing a feature or keybinding people depend on).
- A session-restoration / persistence format change that old versions can't read.
- A deliberate "1.0 → 2.0"-scale release the maintainer is branding as a milestone.

### MINOR (`x.Y.0`) — new features, backward compatible
Reset PATCH to 0. Bump MINOR when:
- A new user-facing feature lands (a new CRT preset, a new palette command, split
  pane enhancements, drag-and-drop, a new emulation capability, a new setting).
- A meaningful new capability that adds to the app without breaking existing use.
- **This is the default for "a feature change."**

### PATCH (`x.y.Z`) — fixes and polish, no new feature
Bump PATCH when:
- A bug fix, performance improvement, rendering tweak, or correctness fix.
- Small polish, copy changes, dependency bumps — anything user-facing that isn't a
  new feature and isn't breaking.

Pure internal changes with **no** user-facing effect (refactors, test-only changes,
CI/build tweaks, doc edits) do **not** need a bump. If unsure whether a change is
user-facing, treat it as PATCH rather than skipping.

> Mapping from Conventional Commits, if commits use them:
> `feat!:` / `BREAKING CHANGE:` → MAJOR · `feat:` → MINOR · `fix:`/`perf:` → PATCH.

## How to bump

1. **Read the current version**: read `marketing_version.txt`.
2. **Decide the component** using the conventions above. If the change set is
   ambiguous (mixes a feature and fixes → take the highest: feature ⇒ MINOR), or if
   you genuinely can't tell major-vs-minor, ask the user which they intend rather
   than guessing on a MAJOR bump.
3. **Compute the new version**, resetting lower components to 0 (MINOR bump zeroes
   PATCH; MAJOR bump zeroes MINOR and PATCH).
4. **Write** the new `MAJOR.MINOR.PATCH` line back to `marketing_version.txt`
   (single line, trailing newline, no other content).
5. **Commit** with the conventional message used in this repo: `Bump marketing
   version` (or `Bump marketing version to X.Y.Z`). Only commit if the user wants a
   commit — otherwise leave the edit staged for their own commit. Don't commit
   unrelated working-tree changes.

### Examples
- Land a new CRT preset → `1.0.1` → **`1.1.0`** (MINOR).
- Fix a parser bug → `1.1.0` → **`1.1.1`** (PATCH).
- Change the session-restore format so old builds can't load it → `1.1.1` →
  **`2.0.0`** (MAJOR).

## Do not
- Edit `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.pbxproj`.
- Touch the build number — it's derived automatically.
- Bump for internal-only changes with no user-facing effect.
