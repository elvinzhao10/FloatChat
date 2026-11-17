# Quick Chat Omni 0.2.0 release audit

Reviewed November 17, 2026. This is a source review and functional verification, not an independent penetration test.

## Verified

- Provider addresses are canonical HTTPS URLs. Embedded credentials, HTTP URLs and duplicate addresses are rejected. Stored custom addresses are revalidated when loaded.
- Each website has one instant slot; pinned conversations have independent identities. Pinned URLs are serialized, revalidated on launch, and stay fixed as the user navigates. Unpinning closes the saved tab and returns to an existing instant page without replacing it. There is no separate add-tab control. Session tabs share website cookies, rather than acting as separate account profiles.
- Provider ordering survives relaunch. Removing or hiding the active provider selects a valid replacement. At least one website remains available.
- Removing a website preserves website storage and account data. The app offers a confirmed website-data reset in Settings → General → Privacy. Reset closes the active and retained web views and blocks reopening until WebKit completes the clear.
- Draft preservation was observed across a ChatGPT → Claude → ChatGPT switch. Automated checks cover oldest-first eviction, the three-inactive-page cap, expiry and immediate release, independent session keys, pinned URL restoration and unpinning. Expiring an instant page clears its remembered in-memory URL; pinned descriptors remain.
- Inactive pages cannot open upload dialogs or request media permissions. Switching away or hiding the panel stops camera/microphone capture and suspends media playback. Capture is not automatically restarted.
- Navigation rejects non-HTTPS/local protocol schemes. Generated blob/data exports use WebKit's download flow. TLS verification is left to WebKit; no certificate bypass, injected credential bridge or browser-cookie import is implemented.
- Icons are bundled locally, with full accessible names and hover labels. No favicon service or background icon fetch runs in the app.
- Shortcut availability was verified by registering a temporary uncommon shortcut, detecting its conflict, releasing it, and confirming availability again. Known macOS Space combinations and local tab-switch combinations are reserved. Local shortcuts owned by other apps cannot be comprehensively detected.
- Settings opens directly from the panel, without an intervening menu. Borderless popup tabs support native drag reordering within instant/pinned groups. The single tab strip scrolls horizontally with its scrollbar hidden; a separator divides instant and pinned groups. Native tooltips show only topic text, without fetching previews.
- The website manager hides the floating panel while open, avoiding click interception. Native moving/resizing was confirmed by the user in the prior revision and remains intact.
- Standard WebKit file drop/paste behavior and the native NSOpenPanel upload delegate are preserved. No DOM-based file injection or upload automation is used.
- Provider/cache tests and inherited keymap regression tests pass. Test preferences use an isolated temporary suite. Shell scripts pass syntax checks.
- Release packaging verifies code signatures after ZIP extraction and verifies the disk image. Both Mach-O slices target macOS 14.0.

## Important limits

- Authenticated uploads, screenshot drops and every provider's SSO/passkey flow have not been tested with real signed-in accounts. Providers can restrict embedded browsers; browser handoff is the fallback.
- WebKit storage follows ordinary website origin/cookie rules in one app-specific store. Each provider is not a separate browser profile. Browser handoff transfers the URL, not cookies or unsent drafts.
- Retained websites can continue JavaScript/network activity and consume memory. Retention is configurable; expiry, removal and hiding a provider release retained views. WebKit can reclaim pages under pressure. No whole-system CPU or memory benchmark is claimed.
- ChatGPT shortcut integration is opt-in. It can temporarily change ChatGPT's shortcut configuration, with backup/restore behavior covered by the inherited tests.
- Packages are ad-hoc signed, not Developer ID signed or Apple-notarized. A first-launch Gatekeeper approval is expected on other Macs. This machine has no valid signing identity.
