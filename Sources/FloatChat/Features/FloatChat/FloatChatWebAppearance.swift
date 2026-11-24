import AppKit
import WebKit

extension FloatChatController {
    func observePageColor(_ view: WKWebView) {
        pageURLObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.webView === view else { return }
                self.dictationPreview.checkAddress(in: view)
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
           effectivePanelTranslucency == 0 || color.alphaComponent == 1 {
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
            const before = ':is(#floatchat-canvas, [data-floatchat-clear-before])::before';
            const after = ':is(#floatchat-canvas, [data-floatchat-clear-after])::after';
            let rules = 'html:root, html:root body, ' + canvas + ' { background-color: transparent !important; }'
                + [backdrop, before, after].join(', ') + ' { background: none !important; -webkit-backdrop-filter: none !important; backdrop-filter: none !important; box-shadow: none !important; }'
                + drawer + ' { background-color: rgba(' + drawerTint + ', 0.94) !important; }';
            if (host === 'chatgpt.com' || host === 'www.chatgpt.com') {
                // Decorative footer layers can have pointer-events:none and paint via pseudo-elements.
                const footer = ':is(#thread-bottom, #thread-bottom-container, [data-thread-scroll-footer])';
                const header = ':is(#page-header, #thread-header)';
                const paint = footer + ' :is(div, span):is([aria-hidden="true"], .pointer-events-none):empty';
                const edges = [header, header + '::before', header + '::after',
                    footer, footer + '::before', footer + '::after',
                    paint, paint + '::before', paint + '::after'];
                rules += edges.join(', ') + ' { background: none !important; backdrop-filter: none !important; box-shadow: none !important; }';
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
        let translucent = effectivePanelTranslucency > 0
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
                const pseudoMarkers = ['data-floatchat-clear-before', 'data-floatchat-clear-after'];
                const host = location.hostname.replace(/^www\./, '');
                const composerSelector = host === 'chatgpt.com' ? '#prompt-textarea'
                    : host === 'claude.ai' ? '.ProseMirror[contenteditable="true"]' : null;
                const translucent = \#(translucent);
                \#(Self.canvasStylesheet)
                const root = document.documentElement;
                let marked = previous?.surfaces ?? new Set();
                let drawers = previous?.drawers ?? new Set();
                let composerLayers = previous?.composerLayers ?? new Set();
                let pseudoLayers = previous?.pseudoLayers ?? [new Set(), new Set()];
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
                const protectedContent = 'button, input, textarea, [contenteditable], [role="button"], article, [data-message-author-role]';
                const hasPaint = style => style.backgroundImage !== 'none' || style.boxShadow !== 'none'
                    || (style.backdropFilter && style.backdropFilter !== 'none')
                    || (style.backgroundColor !== 'transparent' && style.backgroundColor !== 'rgba(0, 0, 0, 0)');
                const reconcile = (before, after, attribute) => {
                    for (const node of before) if (!after.has(node)) node.removeAttribute(attribute);
                    for (const node of after) if (!before.has(node)) node.setAttribute(attribute, '');
                    return after;
                };

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
                    const edgePaint = new Set();
                    const nextPseudoLayers = [new Set(), new Set()];
                    const checkedPaint = new Map();
                    const checkGeneratedPaint = (node, width, minimum) => {
                        if ((checkedPaint.get(node) ?? Infinity) <= minimum) return;
                        checkedPaint.set(node, minimum);
                        for (let index = 0; index < pseudoMarkers.length; index++) {
                            const style = getComputedStyle(node, index === 0 ? '::before' : '::after');
                            if (style.content !== '""' && style.content !== "''") continue;
                            if ((style.position !== 'absolute' && style.position !== 'fixed') || !isSquare(style)) continue;
                            const explicitWidth = Number.parseFloat(style.width);
                            const fillsWidth = Number.isFinite(explicitWidth) ? explicitWidth >= minimum
                                : style.left !== 'auto' && style.right !== 'auto' && width >= minimum;
                            // Once marked, the stylesheet removes this paint. Recheck geometry
                            // on subsequent passes without repeatedly toggling the stylesheet.
                            if (fillsWidth && (hasPaint(style) || pseudoLayers[index].has(node))) {
                                nextPseudoLayers[index].add(node);
                            }
                        }
                    };
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
                                const top = size.width >= innerWidth * 0.55 && size.top <= edgeInset && size.bottom > 1
                                    && size.height <= Math.min(140, innerHeight * 0.25)
                                    && (fullWidth || (composerSelector && node.matches('header, [role="banner"]')));
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
                                if ((canvas || pane || top || ((bottom || insetBottom) && insetBackdrops.get(node))) && !node.closest(protectedContent)) {
                                    const modal = node.closest('dialog, [role="dialog"], [aria-modal="true"]');
                                    if (modal) {
                                        if (!modalNavigation.has(modal)) modalNavigation.set(modal, !!modal.querySelector(navigation));
                                        if (!pane || !modalNavigation.get(modal)) {
                                            node = node.parentElement;
                                            continue;
                                        }
                                    }
                                    surfaces.add(node);
                                    if (composerSelector && !pane && (top || ((bottom || insetBottom) && insetBackdrops.get(node)))
                                        && isSquare(getComputedStyle(node))) {
                                        edgePaint.add(node);
                                        checkGeneratedPaint(node, size.width, size.width * 0.75);
                                    }
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
                        if (composerSelector) sample(Math.min(18, innerHeight - 1), false);
                        sample(Math.floor(innerHeight * 0.75), false);
                        sample(innerHeight - 2, false);
                        sample(Math.max(1, innerHeight - edgeInset), false);
                        const composer = getComposer();
                        if (composerResize && composer !== observedComposer) {
                            composerResize.disconnect();
                            if (composer) composerResize.observe(composer);
                            observedComposer = composer;
                        }
                        const nextComposerLayers = edgePaint;
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
                            if (host === 'chatgpt.com' && editor.bottom >= innerHeight * 0.55) {
                                // The bottom paint can be a portal outside the dock, invisible to
                                // hit tests. Inspect a bounded set of peripheral branches only.
                                const queue = [...document.body.children].slice(-12);
                                for (let i = 0; i < queue.length && i < 36; i++) {
                                    const layer = queue[i];
                                    if (!layer.matches('div, span, footer') || layer.contains(composer)
                                        || layer.closest(protectedContent + ', dialog, [role="dialog"], [aria-modal="true"]')) continue;
                                    const bounds = geometry.get(layer) ?? layer.getBoundingClientRect();
                                    const positionedAtBottom = bounds.width >= Math.max(editor.width * 0.85, 120)
                                        && bounds.left < editor.left + 24 && bounds.right > editor.right - 24
                                        && bounds.top >= editor.top - 16 && bounds.bottom >= innerHeight - 8
                                        && bounds.height > 0 && bounds.height <= Math.min(180, innerHeight * 0.4);
                                    const inert = layer.getAttribute('aria-hidden') === 'true';
                                    if (positionedAtBottom && !layer.childElementCount && !layer.textContent.trim()) {
                                        const style = getComputedStyle(layer);
                                        if (isSquare(style) && (inert || style.pointerEvents === 'none'
                                            || style.position === 'fixed' || style.position === 'absolute')) {
                                            nextComposerLayers.add(layer);
                                            checkGeneratedPaint(layer, bounds.width, bounds.width * 0.75);
                                            observeAncestors(layer);
                                        }
                                    }
                                    if ((positionedAtBottom || inert || bounds.height === 0) && layer.childElementCount <= 5) {
                                        observeAncestors(layer);
                                        queue.push(...layer.children);
                                    }
                                }
                            }
                            for (let node = composer.parentElement, depth = 0; node && depth < 10; node = node.parentElement, depth++) {
                                if (node === document.body || node === root) break;
                                observeAncestors(node);
                                const bounds = geometry.get(node) ?? node.getBoundingClientRect();
                                // Restrict the walk to the dock. The message tree can be very large.
                                if (bounds.height > innerHeight * 0.45) break;
                                if (!nearEditor(bounds)) continue;
                                if (spansEditor(bounds)) {
                                    const style = getComputedStyle(node);
                                    if (bounds.height >= 24 && isSquare(style)) {
                                        nextComposerLayers.add(node);
                                        surfaces.add(node);
                                    }
                                    // A rounded card can own a separate square pseudo-element
                                    // behind it. Keep the card's actual background and controls.
                                    checkGeneratedPaint(node, bounds.width, editor.width * 0.85);
                                }
                                const parent = node.parentElement;
                                if (!parent || parent === root || parent === document.body || parent.childElementCount > 12) continue;
                                const queue = [...parent.children].filter(child => child !== node);
                                for (let i = 0; i < queue.length && i < 18; i++) {
                                    const layer = queue[i];
                                    if (!layer.matches('div, span') || layer.matches(protectedContent)) continue;
                                    const style = getComputedStyle(layer);
                                    const paint = layer.getBoundingClientRect();
                                    const paintedStrip = spansEditor(paint) && nearEditor(paint) && paint.height > 0
                                        && paint.height <= innerHeight * 0.45 && isSquare(style);
                                    if (paintedStrip && !layer.childElementCount && !layer.textContent.trim()
                                        && (style.pointerEvents === 'none' || layer.getAttribute('aria-hidden') === 'true'
                                            || style.position === 'absolute' || style.position === 'fixed')) {
                                        nextComposerLayers.add(layer);
                                        observeAncestors(layer);
                                        checkGeneratedPaint(layer, paint.width, editor.width * 0.85);
                                    } else if (layer.childElementCount <= 4) {
                                        queue.push(...layer.children);
                                    }
                                }
                            }
                        }
                        composerLayers = reconcile(composerLayers, nextComposerLayers, composerMarker);
                        pseudoLayers = pseudoLayers.map((nodes, index) => reconcile(nodes, nextPseudoLayers[index], pseudoMarkers[index]));
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
                        for (let index = 0; index < pseudoMarkers.length; index++) {
                            for (const node of pseudoLayers[index]) node.removeAttribute(pseudoMarkers[index]);
                        }
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
                        get pseudoLayers() { return pseudoLayers; },
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
