<div align="center">
  <img src="Resources/AppIcon-Omni-1024.png" width="104" alt="Quick Chat Omni app icon">
  <h1>Quick Chat Omni</h1>
  <p><strong>Your chat websites in one floating Mac window.</strong></p>
  <p><a href="https://github.com/elvinzhao10/QuickChat-Omni/releases/latest"><strong>Download for Mac</strong></a> · <a href="README.zh-CN.md">简体中文</a> · <a href="CHANGELOG.md">What’s new</a></p>
  <p>macOS 14+ · Apple silicon and Intel</p>
  <p><img src="docs/images/panel.png" width="350" alt="Floating Omni window with provider icons along the top and ChatGPT open"></p>
  <p>ChatGPT · Claude · DeepSeek · Kimi · Gemini · Perplexity · Copilot · Grok</p>
</div>

## Get started

1. Download the **DMG**, open it, and drag **Quick Chat Omni** into **Applications**. The ZIP contains the same app.
2. Open Omni from **Applications**. Use its menu bar icon to reopen the window, or enable the global shortcut in **Settings → General** for **⌥Space** access.
3. Pick a provider icon and sign in on its website with your existing account. Omni works without API keys.

<p><img src="docs/images/menu-bar.png" width="160" alt="Omni’s menu bar icon on light and dark backgrounds"></p>

<details>
<summary>If macOS blocks the first launch</summary>

The community build uses ad-hoc signing and is distributed without Apple notarization. After trying to open it, verify the download came from the official release page, then choose **System Settings → Privacy & Security → Open Anyway**. [Apple’s first-launch guide](https://support.apple.com/en-us/102445)

</details>

## Use the floating window

| To… | Do this |
| --- | --- |
| Switch chats | Click a provider icon or press **⌘1–9**. Scroll the icon strip to reach more tabs. |
| Keep a conversation | Click the pin to save its link. Instant chats and pins share the same strip, separated by a thin line. Hover a pin for its topic. Unpinning closes the saved tab. |
| Move or resize | Drag the top edge to move, drag the corner to resize, or double-click the header to expand and restore. |
| Continue in your browser | Click the arrow to open the current page in your default browser. Use it when a provider requires a browser for sign-in or uploads. |
| Attach or download a file | Use the site’s upload button, paste, or drag a file in where supported. Completed downloads go to Downloads. Click **Show in Finder** to reveal one. |

## Make it yours

<img src="docs/images/websites.png" width="460" alt="Chats settings showing provider visibility switches and fields for adding a website">

Click the sliders icon in the window or choose **Settings…** from the menu bar.

- **Chats** manages websites and pins. Add an HTTPS website, edit its address, rename a pin, drag to reorder, or hide a website with its switch. Right-click a tab to see its hostname or change its zoom.
- **General** manages language, launch at login, shortcuts, and page retention. Websites may use their own saved language settings.

## Page retention and sign-ins

Omni uses native Swift, AppKit, and WebKit. It keeps up to three hidden or inactive pages in memory for up to 10 minutes by default. Choose **Release immediately** in **Settings → General** to free inactive pages sooner. Releasing a page may discard unsent text or interrupt a reply. Pinned links and website sign-ins persist.

Omni and your default browser maintain separate sign-in sessions. Hiding or removing a website keeps its local login. Custom icons are fetched directly from the website over HTTPS in a separate session without chat cookies.

<details>
<summary>Clear website data or uninstall</summary>

Before uninstalling, choose **Settings → General → Privacy → Clear All Website Sign-ins…** and wait for it to finish. This clears local website storage in Omni. If you’ve already moved Omni to Trash, reinstall it from the official release page, run the clear action, then quit and remove it again.

For manual cleanup, quit Omni. In Finder, press **⇧⌘G** and check `~/Library/WebKit`, `~/Library/HTTPStorages`, and `~/Library/Caches`. Move only the folder named `dev.quickchat.omni` to Trash in each location if present. Storage locations vary with macOS version. The in-app reset is the reliable way to clear every Omni sign-in.

</details>

## Project

[Release history](https://github.com/elvinzhao10/QuickChat-Omni/releases) · [Changelog](CHANGELOG.md) · [Release checks](docs/RELEASE-AUDIT.md) · [MIT license](LICENSE)

<details>
<summary>Build from source</summary>

With Apple’s command-line tools installed, run `make app`. The bundle is built at `build/Quick Chat Omni.app`.

</details>

Based on [shuaibird/Quick-Chat](https://github.com/shuaibird/Quick-Chat). Provider names and logos belong to their respective owners.
