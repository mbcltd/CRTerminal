#!/bin/bash
# Build, sign, notarise and (Sparkle-)package a distributable CRTerminal release.
#
# Output (build/release/ — gitignored):
#   CRTerminal.dmg   Developer ID-signed, hardened-runtime, notarised, stapled.
#                    Stable name => stable Sparkle download URL.
#   appcast.xml      Sparkle update feed for this build (only when a Sparkle
#                    signing key is provided — see below).
#
# Versioning:
#   marketing (CFBundleShortVersionString) <- marketing_version.txt   e.g. 1.0.0
#   build     (CFBundleVersion)            <- $BUILD_NUMBER, else git commit count
# Sparkle decides "is there an update?" by comparing CFBundleVersion, so the
# build number MUST strictly increase between releases. CI passes the monotonic
# github.run_number; local builds fall back to the git commit count.
#
# Notarisation credentials — provide ONE of:
#   NOTARY_PROFILE=<name>     a profile saved with `notarytool store-credentials`
#                             (the easy local option; see README/Scripts notes)
#   AC_API_KEY_ID + AC_API_ISSUER_ID + AC_API_KEY_PATH   App Store Connect API key
#                             (the CI option — a scoped, revocable machine key)
#
# Sparkle (optional; when unset the dmg is still built+notarised, appcast skipped):
#   SPARKLE_PRIVATE_KEY=<base64 EdDSA private key>   signs the dmg for Sparkle
#   SPARKLE_SIGN_UPDATE=<path>                       sign_update tool (default: PATH)
#   SPARKLE_FEED_URL / SPARKLE_DOWNLOAD_URL          appcast URLs (sane defaults)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=6JY7V42XFZ
SCHEME=CRTerminal
APP_NAME=crterm          # product name on disk (DerivedData/.../crterm.app)
DMG_NAME=CRTerminal      # stable asset name -> stable releases/latest download URL

MARKETING_VERSION=$(tr -d ' \t\n\r' < marketing_version.txt)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}

ARCHIVE=build/CRTerminal.xcarchive
EXPORT=build/export
OUT=build/release
rm -rf "$ARCHIVE" "$EXPORT" "$OUT"
mkdir -p "$OUT"

echo "==> Archiving CRTerminal $MARKETING_VERSION (build $BUILD_NUMBER)"
# Sign the archive manually with Developer ID. The target defaults to automatic
# signing, which on a CI runner demands a "Mac Development" cert + Apple-account
# login that isn't present — only the Developer ID Application cert is imported.
# A Developer ID app needs no provisioning profile.
xcodebuild -project CRTerminal.xcodeproj -scheme "$SCHEME" \
  -configuration Release -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" archive \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER=""

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist Scripts/ExportOptions.plist \
  -exportPath "$EXPORT"

APP="$EXPORT/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: export produced no $APP" >&2; ls -la "$EXPORT" >&2; exit 1; }

echo "==> Building styled DMG"
command -v dmgbuild >/dev/null 2>&1 || {
  echo "error: dmgbuild not found — install with 'pip install dmgbuild'" >&2; exit 1; }
DMG="$OUT/$DMG_NAME.dmg"
rm -f "$DMG"
# Branded window layout lives in dmg/settings.py + dmg/background.tiff. The
# volume name ("crterm") shows in the Finder title bar; the asset filename stays
# CRTerminal.dmg for the stable Sparkle download URL.
dmgbuild -s dmg/settings.py \
  -D app="$APP" \
  -D bg="$PWD/dmg/background.tiff" \
  "crterm" "$DMG"

echo "==> Notarising"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
elif [ -n "${AC_API_KEY_ID:-}" ]; then
  # Strip stray whitespace/newlines — pasted secrets often carry a trailing \n,
  # which notarytool rejects ("Key ID contains invalid characters").
  KEY_ID=$(printf '%s' "$AC_API_KEY_ID" | tr -d '[:space:]')
  ISSUER_ID=$(printf '%s' "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID}" | tr -d '[:space:]')
  xcrun notarytool submit "$DMG" \
    --key "${AC_API_KEY_PATH:?set AC_API_KEY_PATH}" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER_ID" --wait
else
  echo "error: no notarisation credentials (set NOTARY_PROFILE or AC_API_KEY_ID/ISSUER/PATH)" >&2
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# --- Verification gate ------------------------------------------------------
# `stapler validate` above only proves the *disk image* carries a notarisation
# ticket. Sparkle, though, throws the .app out of the DMG and validates *that* —
# so a DMG that staples fine can still ship an app whose code signature is
# broken/unnotarised, surfacing to users as "The update is improperly signed and
# could not be validated." This gate mounts the finished DMG and verifies the
# exact app a Sparkle update would run, refusing to publish if anything is off.
echo "==> Verifying notarised app inside the DMG (publish gate)"
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
MOUNTED_APP=$(/bin/ls -d "$MOUNT"/*.app 2>/dev/null | head -1)
fail=0
if [ -z "$MOUNTED_APP" ]; then
  echo "  ✗ no .app found inside the DMG" >&2; fail=1
else
  # Code signature intact across the whole bundle (nested frameworks/helpers too).
  codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP" \
    || { echo "  ✗ codesign --verify failed" >&2; fail=1; }
  # Gatekeeper would accept it for execution — only passes once notarised.
  spctl --assess --type execute -vvv "$MOUNTED_APP" \
    || { echo "  ✗ Gatekeeper (spctl) rejects the app for execution" >&2; fail=1; }
  # Signed with a Developer ID Application identity (not ad-hoc/development) and
  # with the hardened runtime — both are prerequisites notarisation can't add
  # after the fact, and a Sparkle host/update identity mismatch shows here.
  desc=$(codesign --display --verbose=4 "$MOUNTED_APP" 2>&1)
  grep -q 'Authority=Developer ID Application' <<<"$desc" \
    || { echo "  ✗ not signed with a Developer ID Application identity" >&2; fail=1; }
  grep -Eq 'flags=.*runtime' <<<"$desc" \
    || { echo "  ✗ hardened runtime flag missing" >&2; fail=1; }
fi
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
rmdir "$MOUNT" 2>/dev/null || true
trap - EXIT
[ "$fail" -eq 0 ] || { echo "error: release verification failed — refusing to publish a bad update" >&2; exit 1; }
echo "  ✓ notarised app verified"

# --- Sparkle appcast (optional) ---------------------------------------------
# Skipped until a Sparkle EdDSA key exists. Once Sparkle is embedded in the app
# (its public key in Info.plist as SUPublicEDKey, feed URL as SUFeedURL), set the
# SPARKLE_PRIVATE_KEY secret and this writes a signed single-item feed advertising
# the just-built dmg as the newest version.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "==> Signing for Sparkle + writing appcast"
  SIGN_UPDATE=${SPARKLE_SIGN_UPDATE:-sign_update}
  # Feed the key via stdin (`--ed-key-file -`); the old `-s <key>` argument form
  # was removed by Sparkle ("Specifying private key as an argument is no longer
  # supported"). Prints e.g.:  sparkle:edSignature="BASE64==" length="12345"
  SIG_ATTRS=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")
  FEED_URL=${SPARKLE_FEED_URL:-https://github.com/mbcltd/CRTerminal/releases/latest/download/appcast.xml}
  DL_URL=${SPARKLE_DOWNLOAD_URL:-https://github.com/mbcltd/CRTerminal/releases/latest/download/$DMG_NAME.dmg}
  MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 26.0)
  PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
  cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>CRTerminal</title>
    <link>$FEED_URL</link>
    <item>
      <title>$MARKETING_VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$MARKETING_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$DL_URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML
else
  echo "==> Skipping Sparkle appcast (set SPARKLE_PRIVATE_KEY to enable)"
fi

echo "==> Release artifacts:"
ls -la "$OUT"
