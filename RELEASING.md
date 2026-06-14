# Releasing CRTerminal

## Distribution: Developer ID, not the Mac App Store

CRTerminal is distributed as a **directly-downloaded, notarised DMG** signed with
the team's *Developer ID Application* certificate (Morgan Brown Consultancy Ltd,
Team ID `6JY7V42XFZ`). It is **deliberately not on the Mac App Store**.

**Why.** The Mac App Store requires every app to enable App Sandbox. A terminal
must `fork`/`exec` the user's login shell with unrestricted access to their files,
network, and child processes — which a sandbox forbids (see the "App Sandbox is
deliberately OFF" note in `CLAUDE.md`). A sandboxed terminal would be crippled, and
App Review reliably rejects the temporary-exception entitlements that might work
around it. Every serious macOS terminal (iTerm2, Ghostty, WezTerm, Warp) ships the
same way for the same reason. So we sign with Developer ID and notarise instead —
users get a Gatekeeper-clean download with no "unidentified developer" warning.

## The pipeline

`.github/workflows/ci.yml` runs the tests on every push/PR. On pushes to `main`
(and via the manual *Run workflow* button) a final `release` job runs **after the
tests pass** and executes `Scripts/release.sh`:

```
archive → Developer ID export → DMG → notarise → staple → GitHub Release
```

`Scripts/release.sh` is the single source of truth and also runs locally.

### Versioning

| Plist key                    | Source                                  |
|------------------------------|-----------------------------------------|
| `CFBundleShortVersionString` | `marketing_version.txt` (e.g. `1.0.0`)  |
| `CFBundleVersion`            | CI: `github.run_number`; local: git commit count |

The build number must strictly increase between releases — Sparkle compares
`CFBundleVersion` to decide whether an update is available, and the monotonic run
number guarantees it. **To bump the marketing version, edit `marketing_version.txt`.**

### Cutting a release

- **CI:** push to `main` (or run the CI workflow manually). A notarised
  `CRTerminal.dmg` appears on the Releases page within ~10 min, tagged
  `v<version>-<run#>`, at the stable URL
  `https://github.com/mbcltd/CRTerminal/releases/latest/download/CRTerminal.dmg`.
- **Local:** `NOTARY_PROFILE=CRTerm-Notary Scripts/release.sh` → `build/release/CRTerminal.dmg`
  (store the profile once with `xcrun notarytool store-credentials`).

### Required GitHub secrets (in the `release` environment, locked to `main`)

| Secret | Purpose |
|---|---|
| `DEVID_CERT_P12_BASE64`, `DEVID_CERT_PASSWORD` | Developer ID Application cert (+ key) as base64 `.p12` |
| `KEYCHAIN_PASSWORD` | ephemeral CI keychain password |
| `AC_API_KEY_ID` (10 chars), `AC_API_ISSUER_ID` (UUID), `AC_API_KEY_P8_BASE64` | App Store Connect API key for notarisation |
| `SPARKLE_PRIVATE_KEY` | EdDSA key that signs the Sparkle appcast (see below) |

## Sparkle auto-updates

The app embeds [Sparkle](https://sparkle-project.org). On launch it checks the
appcast feed declared in its Info.plist and offers in-place updates; users can also
trigger a check from **crterm → Check for Updates…**.

Info.plist keys (in `CRTerminal-Info.plist`):
- `SUFeedURL` → `https://github.com/mbcltd/CRTerminal/releases/latest/download/appcast.xml`
- `SUPublicEDKey` → the EdDSA **public** key; updates whose signature doesn't verify
  against it are refused.
- `SUEnableAutomaticChecks` → `true` (no first-launch prompt).

The matching **private** key lives only in the `SPARKLE_PRIVATE_KEY` GitHub secret
and your keychain. When that secret is present, `Scripts/release.sh` signs the DMG
with Sparkle's `sign_update` and publishes a signed single-item `appcast.xml`
alongside it, pointing at the stable `latest` DMG URL. The feed lists the newest
build, so Sparkle sees every release as an available update.

To rotate or regenerate keys, use Sparkle's `generate_keys` tool; put the new
public key in `CRTerminal-Info.plist` and the exported private key in the secret.
