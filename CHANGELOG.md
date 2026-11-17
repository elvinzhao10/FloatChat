# FloatChat version history

## 0.3.2

### Build 8

- Instant chats and pinned conversations have separate retention timers with no count limit. Instant chats start fresh after expiry. Pins reopen the saved conversation.
- Background translucency follows client-side conversation changes while keeping text opaque.

### Build 7

- One continuous rounded panel surface. The translucency slider changes the background while preserving text and control opacity.
- Custom websites can use a local image as their icon, with an option to restore the website’s favicon.
- Refreshed screenshots and a short explanation of local WebKit sign-ins in both READMEs.

### Build 6

- Doubao (豆包) joins the built-in chat platforms.
- Page zoom has keyboard shortcuts and a per-chat slider in Settings. Each pinned conversation can have its own zoom.
- Settings can stay open alongside the chat panel.
- The floating window can use a translucent background, reopen at its last or default position, and hide when you click away.
- Tabs highlight on hover, open a space during drag, and give haptic feedback when pinned or unpinned on supported trackpads.
- Offline, slow-load, and WebKit failures have visible recovery actions. Inactive pages are released under critical system memory pressure.

## 0.3.1

- The app and GitHub repository are now FloatChat. Existing website sign-ins, pinned links, and settings carry over.
- Keyboard input follows the selected chat when switching tabs.

## 0.3.0

- The retention timer now applies when you hide the window as well as when you switch tabs. Releasing a page keeps website sign-ins and pinned links.
- Downloads save quietly. The floating panel offers **Show in Finder** while it is visible.
- Page-load failures offer **Retry** and **Open in Browser**. Right-click any tab to see its current hostname. Cross-domain pages show the hostname in the window.
- Window size shortcuts are optional. The panel defers its shortcuts while text is being composed and recovers its position when a display is disconnected.
- Settings can edit custom websites, rename pins, and launch FloatChat at login. Use a tab’s context menu to change its website zoom, or **Check for Updates…** in the menu bar.

## 0.2.x version corrections

The original packages all reported version 0.2.0. Each corrected GitHub release has a matching version tag, DMG, ZIP, and checksum file. The original Git tags are retained as source references.

| Corrected version | Original build | Original source tag | Source commit |
| --- | --- | --- | --- |
| [0.2.1](https://github.com/elvinzhao10/FloatChat/releases/tag/v0.2.1) | 1 | `v0.2.0` | `0a972ce` |
| [0.2.2](https://github.com/elvinzhao10/FloatChat/releases/tag/v0.2.2) | 2 | `v0.2.0-build.2` | `07843fc` |
| [0.2.3](https://github.com/elvinzhao10/FloatChat/releases/tag/v0.2.3) | 3 | `v0.2.0-build.3` | `a64cf7f` |
