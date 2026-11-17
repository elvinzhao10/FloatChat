# Quick Chat Omni

A macOS menu-bar companion based on [Quick Chat](https://github.com/shuaibird/Quick-Chat), upstream commit `395dae6`. It uses Swift, AppKit and WebKit; there is no Electron runtime. macOS 14 or later is required.

Enable Quick Chat from the menu-bar icon, then press Option-Space to open the floating, resizable panel. Choose ChatGPT, Claude, DeepSeek, Kimi, Gemini, Perplexity, Copilot or Grok from the native picker. The menu also lets you add an HTTPS provider by name and remove a selected custom provider. The global and window shortcuts can be changed in the menu. The panel retains its size and position.

The floating panel uses one-click provider tabs. Scroll the tab strip to reach additional websites, or press Command–1 through Command–9 to select an enabled provider. Drag empty space in the top strip to move the panel; double-click it to expand or restore. Drag the bottom-right grip to resize. Frame size and position are remembered.

Inactive provider pages stay alive for 10 minutes by default, preserving drafts, page history and scroll position when you switch back. Settings offers immediate release or 1, 5, 10 or 30 minutes. At most three inactive pages are kept; the oldest is released first, and disabling a website releases its retained page. Retained pages may continue network activity and use memory; macOS or WebKit may terminate them under pressure. Expired pages reopen their remembered conversation URL, but unsent drafts and scroll position are not persisted to disk. Website sign-ins remain in WebKit's app-specific data store. Providers can change their sites or reject embedded sign-in flows.

Open Settings from the panel or menu to add HTTPS websites, toggle their visibility and choose retention. The menu provides direct access to opening chat, website visibility, settings, shortcut configuration and clearing local website data. ChatGPT-specific integration is grouped separately.

Passwords are entered into the provider's website, not collected by the app. WebKit manages cookies and storage; the app does not import browser cookies or bypass authentication. The data store is shared by the providers, subject to WebKit's normal origin and cookie rules, and is not a separate security profile for each provider. Use **Clear All Provider Website Data** in the menu to sign out and remove all local web data. Camera and microphone access is prompted only for the selected provider's HTTPS origin, subject to macOS permissions. Treat custom provider URLs as trusted sites. No security audit has been performed.

## Build

Install Apple's command-line developer tools, then run `make app`. Open `build/Quick Chat Omni.app`, enable Quick Chat in its menu, and use the shortcut. The build script signs locally with an available Apple Development identity or ad-hoc; it is not notarized. `make install` installs to `/Applications` and replaces an existing app of the same name. See the upstream repository for additional background and shortcut behavior.

The upstream MIT license and copyright notice are retained in [LICENSE](LICENSE).

## Validation

`QUICKCHAT_SELFTEST=pages swift run QuickChat` runs debug-only cache checks with local, unloaded WebKit views. It checks oldest-first capacity, timed expiry and immediate release without changing saved preferences. Existing keymap checks remain available with `QUICKCHAT_SELFTEST=keymap`.
