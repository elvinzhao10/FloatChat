#!/usr/bin/env bash
# Print a Homebrew cask for a verified, notarized FloatChat release.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: scripts/make-cask.sh VERSION}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a stable X.Y.Z version.' >&2; exit 1; }
dmg="dist/FloatChat-$version.dmg"
xcrun stapler validate "$dmg" >&2
sha="$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)"
cat <<CASK
cask "floatchat" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/elvinzhao10/FloatChat/releases/download/v#{version}/FloatChat-#{version}.dmg"
  name "FloatChat"
  desc "Floating window for your existing AI chat websites"
  homepage "https://github.com/elvinzhao10/FloatChat"

  depends_on macos: ">= :sonoma"

  app "FloatChat.app"
end
CASK
