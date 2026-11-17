# Quick Chat Omni TODO

- Replace the current Grok favicon with a clearer official Grok mark at tab size. Give opaque square favicons rounded corners and preserve transparent artwork. Check contrast in light and dark mode.
- Fetch custom website favicons directly from the website when added or refreshed. Prefer the website's declared icon, fall back to its HTTPS favicon, and cache a small raster version locally. Use a globe when no usable icon is available. Avoid third-party icon services and sending chat cookies on icon requests.
- Add **Settings → General → Privacy → Clear All Website Sign-ins…** with confirmation. Close live and retained web views before clearing Omni's WebKit cookies and website data. Keep the website list, pinned links, and app preferences. Turning off a website should preserve login data.
- Provide an explicit **Remove Local Data Before Uninstalling** flow. Verify where WebKit stores Omni's website data and document how to remove it if the app has already been deleted. Dragging the app bundle to Trash does not run an uninstaller.
