#!/bin/bash
# Publish this release's Homebrew cask to mbcltd/homebrew-tap, so
# `brew install --cask mbcltd/tap/crterm` always installs the newest build.
#
# Usage: Scripts/publish-cask.sh <cask-version> <dmg-path>
#   cask-version   the release tag without the leading v, e.g. 1.15.0-171
#   dmg-path       the notarised DMG the version's release tag serves
#
# Requires TAP_DEPLOY_KEY: an SSH private key whose public half is installed as
# a write-access deploy key on mbcltd/homebrew-tap. The whole cask file is
# regenerated from the template below each release — edit it here, not in the
# tap — and the push is skipped when nothing changed (safe on workflow re-runs).
set -euo pipefail

VERSION=${1:?usage: publish-cask.sh <cask-version> <dmg-path>}
DMG=${2:?usage: publish-cask.sh <cask-version> <dmg-path>}
[ -f "$DMG" ] || { echo "error: no DMG at $DMG" >&2; exit 1; }
SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')

KEY_FILE=$(mktemp)
TAP_DIR=$(mktemp -d)
trap 'rm -rf "$KEY_FILE" "$TAP_DIR"' EXIT
printf '%s\n' "${TAP_DEPLOY_KEY:?set TAP_DEPLOY_KEY}" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

echo "==> Updating Homebrew cask to $VERSION ($SHA256)"
git clone --quiet --depth 1 git@github.com:mbcltd/homebrew-tap.git "$TAP_DIR"

# $VERSION/$SHA256 expand here; the #{version} interpolation is Ruby's, which
# bash leaves alone. ">= :tahoe" (not brew style's bare :tahoe) so the cask
# won't refuse newer macOS releases as they appear.
cat > "$TAP_DIR/Casks/crterm.rb" <<RUBY
cask "crterm" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/mbcltd/CRTerminal/releases/download/v#{version}/CRTerminal.dmg"
  name "crterm"
  desc "Beautifully opinionated terminal emulator with GPU-accelerated retro presets"
  homepage "https://crterm.ai/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "crterm.app"

  zap trash: [
    "~/Library/Application Support/CRTerminal",
    "~/Library/Caches/mbcltd.CRTerminal",
    "~/Library/Preferences/mbcltd.CRTerminal.plist",
    "~/Library/Saved Application State/mbcltd.CRTerminal.savedState",
  ]
end
RUBY

cd "$TAP_DIR"
if git diff --quiet; then
  echo "==> Cask already at $VERSION — nothing to publish"
  exit 0
fi
git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -am "crterm $VERSION"
git push --quiet origin HEAD:main
echo "==> Cask published: brew install --cask mbcltd/tap/crterm"
