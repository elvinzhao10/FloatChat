# FloatChat distribution

Build with the macOS 26 SDK or later using `make app`. Run `swift test` with full Xcode for the headless XCTest target. `make check` also runs the Mac window and WebKit fixtures in a logged-in desktop session. GitHub Actions builds the app and runs XCTest on pushes and pull requests.

## Keep local builds signed with the same identity

Run `./scripts/setup-local-signing.sh` once on the Mac you use for local builds. It stores a FloatChat-specific signing identity in your login Keychain, without changing certificate trust. Subsequent `make app` builds reuse that identity. When migrating from an ad-hoc build, macOS can ask once to authorize the new identity for FloatChat’s existing WebCrypto key. The bundle identifier and website data stay in place. Use Apple Developer ID signing for public distribution.

## Prepare a signed release

1. Install an Apple **Developer ID Application** identity and configure a local keychain profile with `xcrun notarytool store-credentials`.
2. Download the framework and tools from the [official Sparkle releases](https://github.com/sparkle-project/Sparkle/releases) and verify the archive against the release digest. Use Sparkle 2.10.1 or later. Run `bin/generate_keys --account floatchat` once. Keep the private key in Keychain and back it up securely.
3. Set these values in the release shell. Use a build number greater than every previously distributed FloatChat build.

   ```sh
   export VERSION=X.Y.Z BUILD_NUMBER=N UNIVERSAL=1
   export CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
   export NOTARY_PROFILE='floatchat-notary'
   export SPARKLE_FRAMEWORK='/absolute/path/to/Sparkle.framework'
   export SPARKLE_PUBLIC_KEY='public key printed by generate_keys'
   export SPARKLE_FEED_URL='https://elvinzhao10.github.io/FloatChat/appcast.xml'
   make app
   ./scripts/package-release.sh
   ```

   Packaging submits and staples the app and DMG before writing the final ZIP, DMG, and checksums into `dist/`.

4. Upload the packages and checksums to the matching GitHub release. Generate the signed appcast from a directory containing only that release's ZIP and optional matching release notes. Leave deltas off when each release uses its own download directory.

   ```sh
   appcast_work="$(mktemp -d)"
   cp "dist/FloatChat-$VERSION.zip" "$appcast_work/"
   /absolute/path/to/sparkle/bin/generate_appcast --account floatchat --maximum-deltas 0 \
     --embed-release-notes \
     --download-url-prefix "https://github.com/elvinzhao10/FloatChat/releases/download/v$VERSION/" \
     "$appcast_work"
   ```

   Publish the generated `appcast.xml` without editing it at the configured HTTPS feed URL. For the example above, enable GitHub Pages for the repository and publish the file to its Pages root. Before announcing the release, try **Check for Updates…** from an earlier Developer ID-signed build with the same feed and verify the install in place. Users of earlier ad-hoc builds need a one-time download.

## Homebrew

Generate the cask from the final stapled disk image with `./scripts/make-cask.sh "$VERSION"`. Put the output in `Casks/floatchat.rb` in the `elvinzhao10/homebrew-tap` repository and verify it with `brew audit --cask --strict elvinzhao10/tap/floatchat` after the assets are live. Once published, users can run `brew tap elvinzhao10/tap` followed by `brew install --cask floatchat`. Availability without tapping first requires acceptance into the [central Homebrew cask repository](https://docs.brew.sh/Acceptable-Casks).
