import AppKit
import AVFoundation
import WebKit
import os

/// Bounded PCM storage. The HAL drops a block instead of waiting on the UI thread.
final class WebsiteAudioBuffer: Sendable {
    private struct State {
        var samples = [Float](repeating: 0, count: 192_000)
        var end = 0
        var count = 0
    }
    private let storage = OSAllocatedUnfairLock(initialState: State())

    func append(_ samples: UnsafePointer<Float>, count: Int) {
        let address = UInt(bitPattern: samples)
        // This synchronous closure only uses the pointer while the HAL owns the block.
        _ = storage.withLockIfAvailable { state in
            guard let samples = UnsafePointer<Float>(bitPattern: address) else { return }
            let first = min(count, state.samples.count - state.end)
            state.samples.withUnsafeMutableBufferPointer { ring in
                guard let base = ring.baseAddress else { return }
                (base + state.end).update(from: samples, count: first)
                base.update(from: samples + first, count: count - first)
            }
            state.end = (state.end + count) % state.samples.count
            state.count = min(state.count + count, state.samples.count)
        }
    }

    func take(maximum: Int) -> Data {
        storage.withLock { state in
            let count = min(state.count, maximum)
            let start = (state.end - count + state.samples.count) % state.samples.count
            let first = min(count, state.samples.count - start)
            var data = Data()
            data.reserveCapacity(count * MemoryLayout<Float>.size)
            state.samples.withUnsafeBufferPointer { ring in
                guard let base = ring.baseAddress else { return }
                data.append(UnsafeBufferPointer(start: base + start, count: first))
                data.append(UnsafeBufferPointer(start: base, count: count - first))
            }
            state.count = 0
            return data
        }
    }
}

@MainActor
final class WebsiteAudioRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let handler = "floatChatWebsiteAudio"
    private weak var controller: FloatChatController?
    private weak var activePage: WKWebView?
    private weak var requestingPage: WKWebView?
    private var capture: (any CombinedRecording)?
    private var buffer: WebsiteAudioBuffer?
    private var sampleRate = 0.0
    private var token: UUID?
    private var lastPull = Date.distantPast
    private var timer: Timer?
    private var requestID: UUID?
    private var captions: (any DictationCaptionInput)?

    init(controller: FloatChatController) { self.controller = controller }

    var audioLevel: Float { capture?.audioLevel ?? 0 }

    func stopCaptions() {
        captions?.stop()
        captions = nil
    }

    func isCapturing(_ view: WKWebView?) -> Bool {
        guard let view else { return false }
        return activePage === view
    }

    func stop(in view: WKWebView? = nil) {
        if view == nil || requestingPage === view {
            requestID = nil
            requestingPage = nil
        }
        guard let page = activePage, view == nil || page === view else { return }
        activePage = nil
        token = nil
        stopCaptions()
        capture?.stop()
        capture = nil
        buffer = nil
        timer?.invalidate()
        timer = nil
        controller?.dictationPreview.captureEnded(in: page)
        controller?.websiteCaptureChanged(in: page)
    }

    nonisolated static func supports(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", (url.port ?? 443) == 443,
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let controller, let page = message.webView, message.frameInfo.isMainFrame,
              Self.supports(message.frameInfo.request.url), Self.supports(page.url),
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == page.url?.host,
              [0, 443].contains(message.frameInfo.securityOrigin.port),
              let body = message.body as? [String: String] else { return replyHandler(nil, "Invalid audio request.") }

        if body["action"] == "start" {
            let provider = controller.providers[controller.selectedIndex]
            guard page === controller.webView, controller.panel?.isVisible == true,
                  controller.isProviderHost(page.url?.host, provider: provider) else {
                return replyHandler(nil, "Open the chat window to share audio.")
            }
            guard controller.preferences.bool(forKey: "websiteMacAudio") else {
                return replyHandler(nil, "Website dictation is turned off.")
            }
            guard activePage == nil, requestID == nil, !controller.meetingRecorder.isBusy,
                  let panel = controller.panel, panel.attachedSheet == nil else {
                return replyHandler(nil, "An audio session is already active.")
            }
            requestAccess(page: page, panel: panel, reply: replyHandler)
        } else {
            guard page === activePage, let token, body["token"] == token.uuidString else {
                return replyHandler(nil, "Audio sharing ended.")
            }
            switch body["action"] {
            case "pull":
                lastPull = .now
                let pcm = buffer?.take(maximum: Int(sampleRate)) ?? Data()
                if captions != nil, !controller.dictationPreview.canWatch(page) { stopCaptions() }
                captions?.append(pcm)
                let payload = pcm.base64EncodedString()
                replyHandler(payload, nil)
            case "stop":
                stop(in: page)
                replyHandler(true, nil)
            default:
                replyHandler(nil, "Invalid audio request.")
            }
        }
    }

    private func requestAccess(page: WKWebView, panel: NSWindow, reply: @escaping @MainActor (Any?, String?) -> Void) {
        let address = page.url
        let id = UUID()
        requestID = id
        requestingPage = page
        let alert = NSAlert()
        alert.messageText = AppText.t("Share Mac audio with this chat?")
        alert.informativeText = (page.url?.host ?? "") + "\n" +
            AppText.t("The website can transcribe your microphone and Mac playback while its microphone is active.")
        if #available(macOS 26, *), controller?.preferences.bool(forKey: "hiddenDictationPreview") == true {
            alert.informativeText += "\n\n" + AppText.t("FloatChat also uses on-device speech recognition for the floating captions. The first use may download a language model from Apple.")
        }
        alert.addButton(withTitle: AppText.t("Share Mac Audio"))
        alert.addButton(withTitle: AppText.t("Cancel"))
        alert.beginSheetModal(for: panel) { [weak self, weak page] response in
            guard let self, let page, self.requestID == id,
                  self.controller?.webView === page, self.controller?.panel?.isVisible == true, page.url == address else {
                if self?.requestID == id { self?.stop(in: page) }
                return reply(nil, "Audio request ended.")
            }
            if response != .alertFirstButtonReturn {
                self.stop(in: page)
                reply(nil, "Audio sharing was canceled.")
                return
            }
            Task { @MainActor in
                let permission = AVCaptureDevice.authorizationStatus(for: .audio)
                let allowed = if permission == .notDetermined { await AVCaptureDevice.requestAccess(for: .audio) }
                              else { permission == .authorized }
                guard self.requestID == id, self.controller?.webView === page,
                      self.controller?.panel?.isVisible == true, page.url == address,
                      self.controller?.preferences.bool(forKey: "websiteMacAudio") == true else {
                    if self.requestID == id { self.stop(in: page) }
                    return reply(nil, "Audio request ended.")
                }
                self.requestID = nil
                self.requestingPage = nil
                guard allowed, #available(macOS 14.2, *) else {
                    self.controller?.showRecordingNotice("Allow FloatChat microphone access to share Mac audio.")
                    return reply(nil, "Microphone access is unavailable.")
                }
                let pcm = WebsiteAudioBuffer()
                do {
                    let capture = try CombinedAudioCapture(stream: pcm)
                    self.buffer = pcm
                    self.capture = capture
                    self.sampleRate = capture.sampleRate
                    self.token = id
                    self.activePage = page
                    self.lastPull = .now
                    self.monitor()
                    self.startCaptions(in: page, token: id)
                    self.controller?.websiteCaptureChanged(in: page)
                    reply(["token": id.uuidString, "sampleRate": capture.sampleRate], nil)
                } catch {
                    self.controller?.showRecordingNotice("System audio couldn’t start.")
                    reply(nil, "Allow system audio in macOS Privacy & Security, then try again.")
                }
            }
        }
    }

    private func startCaptions(in page: WKWebView, token: UUID) {
        guard let controller, controller.preferences.bool(forKey: "hiddenDictationPreview") else { return }
        let preview = controller.dictationPreview
        preview.captureStarted(in: page)
        guard #available(macOS 26, *) else { preview.captionsUnavailable(); return }
        let locale = Locale(identifier: AppText.webTag(for: controller.language))
        captions = LiveDictationCaptions(sampleRate: sampleRate, locale: locale, onText: { [weak self] text in
            guard let self, self.token == token else { return }
            self.controller?.dictationPreview.updateCaption(text)
        }, onUnavailable: { [weak self] in
            guard let self, self.token == token else { return }
            self.stopCaptions()
            self.controller?.dictationPreview.captionsUnavailable()
        })
        if captions == nil { preview.captionsUnavailable() }
    }

    private func monitor() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.capture?.isRunning != true || Date.now.timeIntervalSince(self.lastPull) > 8 { self.stop() }
            }
        }
        timer.tolerance = 0.5
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

extension WebsiteAudioRelay {
    static let script = #"""
        (() => {
            if (location.protocol !== 'https:' || (location.port && location.port !== '443')) return;
            if (globalThis.floatChatWebsiteAudioInstalled) return;
            const devices = navigator.mediaDevices;
            const bridge = window.webkit?.messageHandlers?.floatChatWebsiteAudio;
            if (!devices || !bridge || !window.AudioContext) return;
            globalThis.floatChatWebsiteAudioInstalled = true;
            const get = devices.getUserMedia.bind(devices);
            let warmed = null;
            let expiry;
            let sharing = false;

            const prepare = () => {
                const context = new AudioContext();
                return {context, ready: context.resume().then(() => true, () => false)};
            };
            // Chat sites can await a network response before requesting their stream.
            // Reserve the Web Audio gesture early. This opens no recording device.
            const prime = event => {
                if (!globalThis.floatChatWebsiteAudioEnabled || warmed || sharing || !event.isTrusted) return;
                if (!(event.target instanceof Element) || !event.target.closest('button, [role="button"]')) return;
                warmed = prepare();
                expiry = setTimeout(() => { warmed?.context.close(); warmed = null; }, 8000);
            };
            document.addEventListener('click', prime, true);
            devices.getUserMedia = async constraints => {
                if (!constraints?.audio) return get(constraints);
                if (!globalThis.floatChatWebsiteAudioEnabled) {
                    throw new DOMException('Website dictation is turned off in FloatChat.', 'NotAllowedError');
                }
                if (sharing) throw new DOMException('An audio session is already active.', 'NotReadableError');
                const prepared = warmed ?? prepare();
                warmed = null;
                clearTimeout(expiry);
                const {context, ready} = prepared;
                sharing = true;
                let session;
                try {
                    const running = await Promise.race([
                        ready, new Promise(resolve => setTimeout(() => resolve(false), 1800))
                    ]);
                    if (!running) throw new Error('Tap the website microphone again to start audio.');
                    session = await bridge.postMessage({action: 'start'});
                } catch (error) {
                    sharing = false;
                    context.close();
                    throw new DOMException(String(error), 'NotAllowedError');
                }
                const send = action => bridge.postMessage({action, token: session.token});
                const media = context.createMediaStreamDestination();
                const track = media.stream.getAudioTracks()[0];
                const nativeStop = track.stop.bind(track);
                let end = false;
                let wake;
                let cursor = 0;
                const stop = () => {
                    if (end) return;
                    end = true;
                    sharing = false;
                    clearTimeout(wake);
                    nativeStop();
                    context.close();
                    send('stop').catch(() => {});
                    window.removeEventListener('pagehide', stop);
                };
                track.stop = stop;
                track.addEventListener('ended', stop, {once: true});
                window.addEventListener('pagehide', stop, {once: true});
                const pull = async () => {
                    if (end || track.readyState !== 'live') { stop(); return; }
                    try {
                        const encoded = await send('pull');
                        if (end) return;
                        if (encoded) {
                            const content = Uint8Array.fromBase64 ? Uint8Array.fromBase64(encoded) : Uint8Array.from(atob(encoded), byte => byte.charCodeAt(0));
                            const samples = new Float32Array(content.buffer);
                            const audio = context.createBuffer(1, samples.length, session.sampleRate);
                            audio.copyToChannel(samples, 0);
                            const source = context.createBufferSource();
                            source.buffer = audio;
                            source.connect(media);
                            if (cursor < context.currentTime || cursor > context.currentTime + 1.5) {
                                cursor = context.currentTime + 0.12;
                            }
                            source.start(cursor);
                            cursor += audio.duration;
                        }
                        wake = setTimeout(pull, 95);
                    } catch (_) { stop(); }
                };
                pull();
                if (constraints.video) {
                    try {
                        const video = await get({audio: false, video: constraints.video});
                        video.getVideoTracks().forEach(track => media.stream.addTrack(track));
                    } catch (error) {
                        stop();
                        throw error;
                    }
                }
                return media.stream;
            };
        })();
        """#
}
