import AppKit
import WebKit

extension FloatChatController {
    func observePageColor(_ view: WKWebView) {
        pageURLObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.webView === view else { return }
                self.rememberPinnedPage()
                self.updateWebsiteIdentity()
                self.requestPageAppearance(for: view)
            }
        }
        pageTitleObservation = view.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { if self?.webView === view { self?.rememberPinnedPage(); self?.updateTabPreviews() } }
        }
        pageColorObservation = view.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.syncPageChrome(view) }
        }
    }

    /// WebKit reports the page canvas color as it changes, including website theme switches.
    /// Match the native controls to that canvas without changing the site's layout or DOM.
    private func syncPageChrome(_ webView: WKWebView) {
        if let color = webView.underPageBackgroundColor,
           panelTranslucency == 0 || color.alphaComponent == 1 {
            setSurfaceColor(color)
        }
        requestPageAppearance(for: webView)
    }

    func requestPageAppearance(for view: WKWebView) {
        guard view === webView, pageAppearanceTimer == nil else { return }
        pageAppearanceTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageAppearanceTimer = nil
                if let view { self.matchPageEdge(view) }
            }
        }
    }

    func cancelPageAppearance() {
        pageAppearanceTimer?.invalidate()
        pageAppearanceTimer = nil
    }

    private func setSurfaceColor(_ color: NSColor) {
        guard surfaceColor != color else { return }
        surfaceColor = color
        applySurfaceAppearance()
        if let rgb = color.usingColorSpace(.sRGB) {
            let brightness = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            chromeView?.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
        }
    }
    // Keep the startup and live rules together so reloads and in-page navigation agree.
    static let canvasStylesheet = #"""
        const canvasStyleID = 'floatchat-canvas';
        const installCanvasStyle = (drawerTint = '32, 32, 32') => {
            const host = location.hostname;
            // Match app-owned markers with enough specificity to override provider theme utilities.
            const canvas = ':is(#floatchat-canvas, [data-floatchat-canvas])';
            const backdrop = ':is(#floatchat-canvas, [data-floatchat-composer-backdrop])';
            const drawer = ':is(#floatchat-canvas, [data-floatchat-drawer])';
            let rules = 'html:root, html:root body, ' + canvas + ' { background-color: transparent !important; }'
                + backdrop + ', ' + backdrop + '::before, ' + backdrop + '::after { background: none !important; backdrop-filter: none !important; }'
                + drawer + ' { background-color: rgba(' + drawerTint + ', 0.94) !important; }';
            if (host === 'chatgpt.com' || host === 'www.chatgpt.com') {
                // Decorative footer layers can have pointer-events:none and paint via pseudo-elements.
                const footer = ':is(#thread-bottom, #thread-bottom-container, [data-thread-scroll-footer="true"])';
                rules += footer + ', ' + footer + '::before, ' + footer + '::after, '
                    + footer + ' div:is([aria-hidden="true"], .pointer-events-none):empty { background: none !important; }';
            }
            let sheet = document.getElementById(canvasStyleID);
            if (!sheet) {
                sheet = document.createElement('style');
                sheet.id = canvasStyleID;
                document.documentElement.append(sheet);
            }
            if (sheet.textContent !== rules) sheet.textContent = rules;
            if (sheet.sheet) sheet.sheet.disabled = false;
        };
        """#

    static let canClearWebBackground = WKWebView.instancesRespond(to: NSSelectorFromString("_setDrawsBackground:"))

    @discardableResult
    func setWebBackground(_ view: WKWebView) -> Bool {
        // Gate WebKit's rendering-only option and keep the page opaque when unavailable.
        guard Self.canClearWebBackground else { return false }
        let translucent = panelTranslucency > 0
        if (view.value(forKey: "drawsBackground") as? Bool) != !translucent {
            view.setValue(!translucent, forKey: "drawsBackground")
        }
        return translucent
    }

    func matchPageEdge(_ view: WKWebView) {
        guard view === webView, let url = view.url else { return }
        let translucent = setWebBackground(view)
        let script = #"""
            (() => {
                const previous = globalThis.floatChatCanvas;
                previous?.stop();
                const marker = 'data-floatchat-canvas';
                const drawerMarker = 'data-floatchat-drawer';
                const composerMarker = 'data-floatchat-composer-backdrop';
                const host = location.hostname.replace(/^www\./, '');
                const composerSelector = host === 'chatgpt.com' ? '#prompt-textarea'
                    : host === 'claude.ai' ? '.ProseMirror[contenteditable="true"]' : null;
                const translucent = \#(translucent);
                \#(Self.canvasStylesheet)
                const root = document.documentElement;
                let marked = previous?.surfaces ?? new Set();
                let drawers = previous?.drawers ?? new Set();
                let composerLayers = previous?.composerLayers ?? new Set();
                let drawerTint = previous?.tint ?? '32, 32, 32';
                let watched = new Set();
                let observedComposer = null;
                let pending = null;
                const schedule = () => {
                    if (pending !== null) return;
                    pending = setTimeout(() => {
                        pending = null;
                        update(false);
                    }, 40);
                };
                const observer = translucent ? new MutationObserver(schedule) : null;
                const composerResize = translucent && composerSelector ? new ResizeObserver(schedule) : null;
                const cornerRadii = ['TopLeft', 'TopRight', 'BottomLeft', 'BottomRight'];
                const isSquare = style => cornerRadii.every(
                    corner => Number.parseFloat(style['border' + corner + 'Radius']) <= 6);
                const getComposer = () => composerSelector ? document.querySelector(composerSelector) : null;

                const update = readColor => {
                    const sheet = document.getElementById(canvasStyleID);
                    if (readColor && sheet?.sheet) sheet.sheet.disabled = true;
                    const surfaces = new Set();
                    const roots = new Set([root]);
                    if (document.body) roots.add(document.body);
                    const geometry = new Map();
                    const colors = new Map();
                    const insetBackdrops = new Map();
                    const edgeInset = 16;
                    const modalNavigation = new Map();
                    const navigation = 'aside, nav, [role="navigation"], [role="complementary"]';

                    const floatingPanes = new Set();
                    const sample = (y, sampleColor) => [0.08, 0.5, 0.92].map(position => {
                        const x = Math.floor(innerWidth * position);
                        const hits = translucent ? document.elementsFromPoint(x, y) : [document.elementFromPoint(x, y)];
                        const visited = new Set();
                        let sampled = null;
                        for (let node of hits) {
                            while (node && !visited.has(node)) {
                                visited.add(node);
                                if (!geometry.has(node)) geometry.set(node, node.getBoundingClientRect());
                                const size = geometry.get(node);
                                const leftEdge = size.left <= 2;
                                const rightEdge = size.right >= innerWidth - 2;
                                const fullWidth = leftEdge && rightEdge;
                                const canvas = size.width >= innerWidth * 0.9 && size.height >= innerHeight * 0.5;
                                const pane = translucent && (leftEdge || rightEdge) && size.width >= innerWidth * 0.24
                                    && size.width < innerWidth * 0.9 && size.height >= innerHeight * 0.65;
                                const top = fullWidth && size.top <= 1 && size.bottom > 1 && size.height <= innerHeight * 0.25;
                                const bottom = fullWidth && size.top < innerHeight - 2 && size.bottom >= innerHeight - 2;
                                const insetBottom = !fullWidth && size.left >= -2 && size.left <= edgeInset
                                    && size.right >= innerWidth - edgeInset && size.right <= innerWidth + 2
                                    && size.bottom >= innerHeight - edgeInset && size.bottom <= innerHeight + 2
                                    && size.height >= 24 && size.height <= innerHeight * 0.45;
                                if ((bottom || insetBottom) && !insetBackdrops.has(node)) {
                                    const style = getComputedStyle(node);
                                    // Keep rounded input cards distinct from the flush or inset backing strip.
                                    insetBackdrops.set(node, isSquare(style));
                                }
                                if ((canvas || pane || top || ((bottom || insetBottom) && insetBackdrops.get(node))) && !node.matches('button, input, textarea, [contenteditable]')) {
                                    const modal = node.closest('dialog, [role="dialog"], [aria-modal="true"]');
                                    if (modal) {
                                        if (!modalNavigation.has(modal)) modalNavigation.set(modal, !!modal.querySelector(navigation));
                                        if (!pane || !modalNavigation.get(modal)) {
                                            node = node.parentElement;
                                            continue;
                                        }
                                    }
                                    surfaces.add(node);
                                    if (pane || (sampleColor && !sampled)) {
                                        if (!colors.has(node)) {
                                            const style = getComputedStyle(node);
                                            const color = style.backgroundColor;
                                            colors.set(node, {
                                                rgb: /^rgb\(/.test(color) ? color.match(/[0-9.]+/g)?.map(Number) : null,
                                                floating: (style.position === 'fixed' || style.position === 'absolute')
                                                    && (node.matches(navigation) || !!node.querySelector(navigation))
                                            });
                                        }
                                        const { rgb, floating } = colors.get(node);
                                        if (pane && floating) floatingPanes.add(node);
                                        if (sampleColor && !sampled) sampled = rgb;
                                    }
                                }
                                node = node.parentElement;
                            }
                        }
                        return sampled;
                    });

                    const consensus = entries => entries.find(color =>
                        color && entries.filter(other => String(other) === String(color)).length > 1);
                    const top = sample(1, readColor);
                    const middle = translucent ? sample(Math.floor(innerHeight * 0.42), readColor) : [];
                    if (translucent) {
                        sample(Math.floor(innerHeight * 0.75), false);
                        sample(innerHeight - 2, false);
                        sample(Math.max(1, innerHeight - edgeInset), false);
                        const composer = getComposer();
                        if (composerResize && composer !== observedComposer) {
                            composerResize.disconnect();
                            if (composer) composerResize.observe(composer);
                            observedComposer = composer;
                        }
                        const nextComposerLayers = new Set();
                        if (composer && !composer.closest('dialog, [role="dialog"], [aria-modal="true"]')) {
                            const editor = composer.getBoundingClientRect();
                            // Docked composers can be narrower than the viewport beside a sidebar or artifact.
                            const spansEditor = bounds => bounds.width >= Math.max(editor.width, 160)
                                && bounds.right >= editor.right - 2 && bounds.left <= editor.left + 2;
                            const nearEditor = bounds => bounds.bottom >= editor.top - 24
                                && bounds.top <= editor.bottom + 96 && editor.bottom >= innerHeight * 0.55;
                            const observeAncestors = node => {
                                for (let parent = node; parent && !roots.has(parent); parent = parent.parentElement) {
                                    roots.add(parent);
                                }
                            };
                            for (let node = composer.parentElement, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
                                if (node === document.body || node === root) break;
                                observeAncestors(node);
                                const bounds = geometry.get(node) ?? node.getBoundingClientRect();
                                if (spansEditor(bounds) && nearEditor(bounds) && bounds.height >= 24
                                    && bounds.height <= innerHeight * 0.45 && isSquare(getComputedStyle(node))) {
                                    nextComposerLayers.add(node);
                                    surfaces.add(node);
                                }
                                // Some layouts paint the band in a separate, empty sibling rather than an ancestor.
                                for (const neighbor of [node.previousElementSibling, node.nextElementSibling]) {
                                    if (!neighbor?.matches('div, span') || neighbor.childElementCount || neighbor.textContent.trim()) continue;
                                    const style = getComputedStyle(neighbor);
                                    if (style.pointerEvents !== 'none' && neighbor.getAttribute('aria-hidden') !== 'true') continue;
                                    const paint = neighbor.getBoundingClientRect();
                                    if (spansEditor(paint) && nearEditor(paint) && paint.height > 0
                                        && paint.height <= innerHeight * 0.45 && isSquare(style)) {
                                        nextComposerLayers.add(neighbor);
                                        roots.add(neighbor);
                                    }
                                }
                            }
                        }
                        for (const node of composerLayers) {
                            if (!nextComposerLayers.has(node)) node.removeAttribute(composerMarker);
                        }
                        for (const node of nextComposerLayers) {
                            if (!composerLayers.has(node)) node.setAttribute(composerMarker, '');
                        }
                        composerLayers = nextComposerLayers;
                        for (const node of marked) {
                            if (!surfaces.has(node)) node.removeAttribute(marker);
                        }
                        for (const node of surfaces) {
                            if (!marked.has(node)) node.setAttribute(marker, '');
                            for (let parent = node; parent && !roots.has(parent); parent = parent.parentElement) roots.add(parent);
                        }
                        marked = surfaces;
                        const nextDrawers = new Set([...floatingPanes].filter(node => {
                            for (let parent = node.parentElement; parent; parent = parent.parentElement) {
                                if (floatingPanes.has(parent)) return false;
                            }
                            return true;
                        }));
                        for (const node of drawers) {
                            if (!nextDrawers.has(node)) node.removeAttribute(drawerMarker);
                        }
                        for (const node of nextDrawers) {
                            if (!drawers.has(node)) node.setAttribute(drawerMarker, '');
                        }
                        drawers = nextDrawers;
                        if (readColor) {
                            const color = consensus(middle) ?? consensus(top);
                            if (color) drawerTint = color.join(', ');
                        }
                        if (readColor || !sheet?.isConnected) installCanvasStyle(drawerTint);
                        if (roots.size !== watched.size || [...roots].some(node => !watched.has(node))) {
                            observer.disconnect();
                            for (const node of roots) {
                                if (node) observer.observe(node, {
                                    childList: true, attributes: true, attributeFilter: ['class', 'style', 'hidden', 'data-state', 'aria-hidden']
                                });
                            }
                            watched = roots;
                        }
                    } else {
                        for (const node of marked) node.removeAttribute(marker);
                        for (const node of drawers) node.removeAttribute(drawerMarker);
                        for (const node of composerLayers) node.removeAttribute(composerMarker);
                        sheet?.remove();
                    }
                    return consensus(middle) ?? consensus(top) ?? null;
                };

                const color = update(true);
                if (translucent) {
                    const onTransition = event => {
                        if (watched.has(event.target) && /^(transform|translate|width|left|right|opacity)$/.test(event.propertyName)) schedule();
                    };
                    const onComposerAction = event => {
                        const composer = getComposer();
                        if (composer && event.target instanceof Element
                            && (composer.contains(event.target) || event.target.contains(composer)
                                || event.target.closest('[data-testid="send-button"], [data-testid="stop-button"]'))) schedule();
                    };
                    window.addEventListener('resize', schedule);
                    document.addEventListener('transitionend', onTransition);
                    if (composerSelector) {
                        document.addEventListener('focusin', onComposerAction, true);
                        document.addEventListener('submit', onComposerAction, true);
                        document.addEventListener('click', onComposerAction, true);
                    }
                    globalThis.floatChatCanvas = {
                        get surfaces() { return marked; },
                        get drawers() { return drawers; },
                        get composerLayers() { return composerLayers; },
                        get tint() { return drawerTint; },
                        stop() {
                            observer.disconnect();
                            composerResize?.disconnect();
                            document.removeEventListener('focusin', onComposerAction, true);
                            document.removeEventListener('submit', onComposerAction, true);
                            document.removeEventListener('click', onComposerAction, true);
                            window.removeEventListener('resize', schedule);
                            document.removeEventListener('transitionend', onTransition);
                            if (pending !== null) clearTimeout(pending);
                        }
                    };
                } else {
                    delete globalThis.floatChatCanvas;
                }
                return color;
            })()
            """#
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak view] result in
            guard let self, let view, self.webView === view, view.url == url,
                  case .success(let value) = result, let rgb = value as? [Double], rgb.count == 3 else { return }
            self.setSurfaceColor(NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1))
        }
    }
}
