# FloatChat release checks

## 0.3.2

### Build 8 (local)

- The provider test retains more than three parked pages and checks independent instant and pin deadlines, immediate release, and migration from the old shared duration.
- The panel test replaces a WebKit canvas in place, checks that translucency returns while text opacity remains at one, and verifies that a pin restores its saved conversation after navigating away.

### Build 6 (published)

- All five local self-tests passed. The panel regression covers independent Settings and chat windows, whole-web-view opacity, offline status recovery, keyboard delivery after switching, draft retention, and eviction. The provider test covers separate pin and instant zoom levels, Doubao registration, and rejection of authentication fragments.
- The isolated macOS app was used to inspect the translucent web page and adjust a per-chat zoom slider. The full set of signed-in provider microphone, camera, passkey, and upload flows remains outside this run.
- The universal package keeps the original macOS bundle identifier and uses ad-hoc signing.

## 0.3.0 (Quick Chat Omni)

## Local checks

- All five debug self-tests passed on the host Mac. The mounted 0.3.0 DMG contains build 4 with arm64 and x86_64 slices, both targeting macOS 14.0. The mounted app and the extracted ZIP passed signature checks. Both downloads match the SHA-256 manifest.

- The provider tests cover URL validation, duplicate rejection, order persistence, independent pinned links, unpinning, language headers, and expiry of the oldest pages after the three-page cap.
- The panel test uses an isolated preferences suite, nonpersistent WebKit pages, and a temporary pasteboard. It exercises the marked-text dismissal guard, native text copy and paste, preservation of an unsent WebKit draft across a switch, hidden selection without attaching a page, and immediate release when hiding. It also verifies the error state of a parked page and recovery of a frame placed outside the visible displays.
- The language tests read navigator language from a real WebKit document in English and Simplified Chinese. The shortcut tests exercise registration conflicts and reserved keys. The inherited keymap tests cover opt-in ChatGPT shortcut integration and rollback.
- Source review covered camera and microphone shutdown during hide and switch, permission prompts limited to the selected visible website, HTTPS main-frame navigation, and rechecking the selected view when an upload picker closes. WebKit performs TLS verification.
- Download destinations have unique names within FloatChat and remain associated with each active download across tab changes. Completion offers a brief Finder action when the panel is visible. Download logging records events and error codes.
- The Grok mark is bundled. Custom favicons are retrieved with a separate cookieless HTTPS session, resized and cached locally. Both READMEs describe clearing website sign-ins before uninstalling and removing local data afterward.

## Installed-app checks

- Upgraded the existing Applications bundle to 0.3.0 under the same bundle identifier. ChatGPT opened with its existing sign-in.
- Pasted mixed English and Chinese text into a temporary ChatGPT composer. Switched to Claude and back with the keyboard and verified the unsent text survived. Claude redirected to its HTTPS sign-in page.
- Opened Settings from the panel, verified the General controls for launch at login, language, retention, shortcuts and privacy, then closed Settings and verified that the composer regained focus.

## Remaining manual coverage

- In a signed-in WebKit composer using Simplified Chinese Pinyin, type a syllable. Press Escape to dismiss composition, press Escape again to hide, then reopen. Copy and paste a draft with ⌘C and ⌘V, switch providers with ⌘1–9, and confirm the original draft stays unsent and intact.
- Open the panel from a different app, type immediately, change Spaces, and return. Click another application during the transition and confirm FloatChat leaves it focused. Close FloatChat from the foreground and verify focus returns to the previous app. Move it to an external monitor and disconnect that monitor.
- Start camera or microphone capture on a supported website. Switch tabs, hide, and reopen. Capture should stop and a website must ask the user to start it again.
- Download an attachment while the panel is visible and again while it is hidden. Check Downloads and confirm Finder opens only after **Show in Finder** is clicked. Try two concurrent downloads with the same suggested name.
- Try a real provider redirect, sign-in, passkey, screenshot drop, and file upload. Use the default browser where a provider restricts the embedded experience. Browser handoff opens the current URL and browser sign-in is separate.
- Try Launch at Login after installing in Applications, including the System Settings approval state. Check the localized General settings and website editing.
- Local packages use ad-hoc signing. Public Developer ID signing and Apple notarization require credentials unavailable on this Mac. macOS may require first-launch approval for the local packages.

The prior release checks are available in the source history under the original tags listed in the [version history](../CHANGELOG.md).
