# Quick Chat Omni

A macOS menu-bar companion based on [Quick Chat](https://github.com/shuaibird/Quick-Chat), upstream commit `395dae6`. It uses Swift, AppKit and WebKit; there is no Electron runtime. macOS 14 or later is required.

Enable Quick Chat from the menu-bar icon, then press Option-Space to open the floating, resizable panel. Choose ChatGPT, Claude, DeepSeek, Kimi, Gemini, Perplexity, Copilot or Grok from the native picker. The menu also lets you add an HTTPS provider by name and remove a selected custom provider. The global and window shortcuts can be changed in the menu. The panel retains its size and position.

Only one web view is loaded at a time. Switching saves the current provider's page address in memory and loads the selected provider; website sessions persist in WebKit's app-specific data store. This saves resources compared with keeping every provider running, but switching reloads the page and unsent text or ongoing generation may be lost. Providers can change their websites or reject embedded WebKit sign-ins, so individual features and login methods are not guaranteed to work. External links from a provider normally open in the default browser; common sign-in hosts remain in the panel.

Passwords are entered into the provider's website, not collected by the app. WebKit manages cookies and storage; the app does not import browser cookies or bypass authentication. The data store is shared by the providers, subject to WebKit's normal origin and cookie rules, and is not a separate security profile for each provider. Use **Clear All Provider Website Data** in the menu to sign out and remove all local web data. Camera and microphone access is prompted only for the selected provider's HTTPS origin, subject to macOS permissions. Treat custom provider URLs as trusted sites. No security audit has been performed.

## Build

Install Apple's command-line developer tools, then run `make app`. Open `build/Quick Chat Omni.app`, enable Quick Chat in its menu, and use the shortcut. The build script signs locally with an available Apple Development identity or ad-hoc; it is not notarized. `make install` installs to `/Applications` and replaces an existing app of the same name. See the upstream repository for additional background and shortcut behavior.

The upstream MIT license and copyright notice are retained in [LICENSE](LICENSE).
