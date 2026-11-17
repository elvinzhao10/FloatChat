# Security

Please report security issues privately using [GitHub’s vulnerability reporting form](https://github.com/elvinzhao10/FloatChat/security/advisories/new). Include the FloatChat and macOS versions, expected and observed behavior, and steps to reproduce with a test account or fixture. Omit passwords, cookies, tokens, and private chat content.

GitHub secret scanning and push protection cover the public repository. FloatChat uses system AppKit and WebKit and has no third-party Swift dependencies. Releases are built manually.

For a local check before packaging, run `make check` on macOS. It runs the Swift debug self-tests and checks shell script syntax. Packaging verifies the app’s code signature and generates a SHA-256 manifest for the DMG and ZIP. To verify a download, put it beside the manifest and run `shasum -a 256 -c FloatChat-<version>.sha256` with both packages present.
