import AppKit
import AVFoundation
import WebKit

#if DEBUG
extension FloatChatController {
    static func runAudioSelfTest() -> Bool {
        _ = NSApplication.shared
        print("Checking mixed audio levels and M4A encoding")
        guard runAudioMixSelfTest(interleaved: false), runAudioMixSelfTest(interleaved: true),
              runAudioMixSelfTest(interleaved: false, systemAudible: false) else { return false }

        print("Checking that the website receives mixed audio and stops its sharing session")
        guard runWebsiteAudioSelfTest() else { return false }

        print("Checking hidden dictation preview isolates new text from the existing draft")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        let url = URL(string: "https://chatgpt.com/c/preview-fixture")!
        view.loadHTMLString("<textarea id='prompt-textarea'>local draft</textarea>", baseURL: url)
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date.now.addingTimeInterval(3)
            while !condition(), Date.now < deadline {
                RunLoop.current.run(until: Date.now.addingTimeInterval(0.025))
            }
            return condition()
        }
        var loaded = false
        guard wait({ view.url == url && !view.isLoading }) else { return false }
        view.evaluateJavaScript("document.querySelector('textarea').value") { value, _ in
            loaded = value as? String == "local draft"
        }
        guard wait({ loaded }) else { return false }
        let preview = DictationPreview()
        let recorder = MeetingRecorder()
        defer {
            preview.clear()
            recorder.updateIndicator(near: nil, action: nil)
        }
        view.evaluateJavaScript("document.querySelector('textarea').hidden = true", completionHandler: nil)
        preview.captureStarted(in: view)
        var action = MeetingRecorder.IndicatorAction.reopenWebsite
        func refresh() {
            recorder.updateIndicator(near: nil, action: action, offersPreview: true, preview: preview.presentation,
                                     onWebsitePress: { _ = preview.toggle(in: view) })
        }
        preview.startWhileHidden(view, onChange: refresh)
        refresh()
        guard let content = NSApp.windows.compactMap({ $0.contentView as? RecordingIndicatorContent }).first,
              let window = content.window, let dot = content.dotFrame else { return false }
        guard recordingIndicatorRendersRed(content.ball) else {
            print("Recording indicator did not render a red center and soft falloff")
            return false
        }
        guard preview.presentation == nil, content.ball.accessibilityPerformPress(),
              window.frame.width > dot.width, content.dotFrame == dot else {
            print("Opening the transcript shifted the dot or failed to expand the window")
            return false
        }
        preview.updateCaption("live spoken words")
        guard preview.presentation == .init(text: "live spoken words", isExcerpt: true) else { return false }
        preview.captureEnded(in: view)
        action = .websiteTranscript
        refresh()
        guard content.window === window, window.frame.width > dot.width,
              preview.presentation?.text == "live spoken words" else { return false }
        view.evaluateJavaScript("""
            const old = document.querySelector('textarea');
            const field = old.cloneNode();
            old.replaceWith(field);
            field.hidden = false;
            field.value = 'local spoken words draft';
            """, completionHandler: nil)
        func excerpt() -> String? { preview.presentation.flatMap { $0.isExcerpt ? $0.text : nil } }
        guard wait({ excerpt() == "spoken words" }) else { return false }
        guard content.ball.accessibilityPerformPress(), preview.presentation == nil, window.frame == dot,
              content.ball.accessibilityPerformPress(), excerpt() == "spoken words", content.dotFrame == dot else { return false }
        view.evaluateJavaScript("document.querySelector('textarea').value = 'replacement draft'", completionHandler: nil)
        guard wait({ excerpt() == "live spoken words" }) else { return false }
        view.evaluateJavaScript("document.querySelector('textarea').value = 'local draft another utterance'", completionHandler: nil)
        guard wait({ excerpt() == "another utterance" }) else { return false }
        preview.pause()
        guard preview.presentation == nil, preview.canWatch(view) else { return false }
        preview.clear(in: view)
        guard !preview.canWatch(view) else { return false }
        print("Audio and dictation preview checks passed")
        return true
    }

    private static func recordingIndicatorRendersRed(_ ball: ActivityBall) -> Bool {
        let size = Int(ActivityBall.recordingSize)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let layer = ball.layer, let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        layer.render(in: context)
        let center = (size / 2 * size + size / 2) * 4
        let glow = center + 8 * 4
        let edge = center + 12 * 4
        return bytes[center] > 180 && bytes[center + 1] < 100
            && bytes[glow] > bytes[edge] && bytes[glow] > bytes[glow + 1]
    }

    private static func runAudioMixSelfTest(interleaved: Bool, systemAudible: Bool = true) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 32_000.0
        let frames: AVAudioFrameCount = 16_000
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: interleaved),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = input.floatChannelData else { return false }
        input.frameLength = frames
        let frequencies = [440.0, 1_070.0]
        for (channel, frequency) in frequencies.enumerated() {
            for index in 0..<Int(frames) {
                let gain = channel == 0 || systemAudible ? 0.2 : 0
                let sample = Float(gain * sin(2 * .pi * frequency * Double(index) / sampleRate))
                if interleaved { channels[0][index * 2 + channel] = sample }
                else { channels[channel][index] = sample }
            }
        }
        do {
            let writer = try MixedAudioWriter(url: url, sampleRate: sampleRate, microphoneChannels: 1)
            writer.write(input.audioBufferList)
            let measured = writer.audioLevel
            guard measured > (systemAudible ? 0.13 : 0.08),
                  measured < (systemAudible ? 0.15 : 0.11), writer.audioLevel == 0 else {
                writer.close()
                return false
            }
            writer.close()
            let file = try AVAudioFile(forReading: url)
            guard !writer.failed, writer.heardSystemAudio == systemAudible, file.processingFormat.channelCount == 1,
                  let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return false }
            try file.read(into: output)
            guard let mixed = output.floatChannelData?[0], output.frameLength >= frames / 2 else { return false }
            let length = Int(output.frameLength)
            return frequencies.enumerated().allSatisfy { channel, frequency in
                var sine = 0.0
                var cosine = 0.0
                for index in 0..<length {
                    let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
                    sine += Double(mixed[index]) * sin(phase)
                    cosine += Double(mixed[index]) * cos(phase)
                }
                let level = hypot(sine, cosine) / Double(length)
                return channel == 0 || systemAudible ? level > 0.04 : level < 0.015
            }
        } catch {
            print("Audio mix test failed: \(error)")
            return false
        }
    }

    private final class AudioRelayFixture: NSObject, WKScriptMessageHandlerWithReply {
        var stopped = false
        private var offset = 0

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            let body = message.body as? [String: String]
            switch body?["action"] {
            case "start":
                replyHandler(["token": "fixture", "sampleRate": 48_000], nil)
            case "pull" where body?["token"] == "fixture":
                let samples = (offset..<(offset + 4560)).map { Float(sin(Double($0) * .pi / 50)) * 0.3 }
                offset += 4560
                replyHandler(samples.withUnsafeBytes { Data($0).base64EncodedString() }, nil)
            case "stop" where body?["token"] == "fixture":
                stopped = true
                replyHandler(true, nil)
            default:
                replyHandler(nil, "Unexpected request")
            }
        }
    }

    private static func runWebsiteAudioSelfTest() -> Bool {
        guard WebsiteAudioRelay.supports(URL(string: "https://chatgpt.com/c/fixture")),
              WebsiteAudioRelay.supports(URL(string: "https://claude.ai/new")),
              !WebsiteAudioRelay.supports(URL(string: "http://chatgpt.com/c/fixture")),
              !WebsiteAudioRelay.supports(URL(string: "https://chatgpt.com:8080/c/fixture")),
              nativeWebsiteCaptureDecision(.microphone, fromTrustedPage: true) == .deny,
              nativeWebsiteCaptureDecision(.cameraAndMicrophone, fromTrustedPage: true) == .deny,
              nativeWebsiteCaptureDecision(.camera, fromTrustedPage: false) == .deny,
              nativeWebsiteCaptureDecision(.camera, fromTrustedPage: true) == .prompt else { return false }

        let fixture = AudioRelayFixture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addScriptMessageHandler(fixture, contentWorld: .page, name: WebsiteAudioRelay.handler)
        let fixtureSetup = """
            globalThis.floatChatWebsiteAudioEnabled = true;
            globalThis.rawMicrophoneCalls = 0;
            navigator.mediaDevices.getUserMedia = async () => {
                globalThis.rawMicrophoneCalls++;
                throw new Error('The real microphone should never be called');
            };
            """
        config.userContentController.addUserScript(WKUserScript(source: fixtureSetup + WebsiteAudioRelay.script,
                                                               injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        view.loadHTMLString("<button style='position:fixed;inset:0'>Local website microphone fixture</button>", baseURL: URL(string: "https://chatgpt.com/c/fixture"))
        let loadDeadline = Date.now.addingTimeInterval(4)
        while view.isLoading && Date.now < loadDeadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.04)) }
        var result: Bool?
        view.callAsyncJavaScript("""
            const button = document.querySelector('button');
            globalThis.fixturePhase = 'Waiting for click';
            return await new Promise((resolve, reject) => {
              button.addEventListener('click', () => run().then(resolve, reject), {once: true});
            });
            async function run() {
            const context = new AudioContext();
            const resumed = context.resume();
            await new Promise(resolve => setTimeout(resolve, 200));
            globalThis.fixturePhase = 'Getting microphone, activation: ' + navigator.userActivation.isActive;
            const stream = await navigator.mediaDevices.getUserMedia({audio: true});
            await resumed;
            globalThis.fixturePhase = 'Recording track';
            const source = context.createMediaStreamSource(stream);
            const analyser = context.createAnalyser();
            const silent = context.createGain();
            silent.gain.value = 0;
            source.connect(analyser).connect(silent).connect(context.destination);
            const recorder = new MediaRecorder(stream);
            const recorded = new Promise(resolve => recorder.addEventListener('dataavailable', event => resolve(event.data.size), {once: true}));
            recorder.start();
            await new Promise(resolve => setTimeout(resolve, 550));
            const samples = new Float32Array(analyser.fftSize);
            analyser.getFloatTimeDomainData(samples);
            recorder.stop();
            const size = await recorded;
            stream.getTracks().forEach(track => track.stop());
            await context.close();
            globalThis.fixturePhase = 'Recorded ' + size + ' bytes, signal: ' + samples.some(sample => Math.abs(sample) > 0.05);
            globalThis.floatChatWebsiteAudioEnabled = false;
            let denied = false;
            try { await navigator.mediaDevices.getUserMedia({audio: true}); }
            catch (_) { denied = true; }
            return denied && globalThis.rawMicrophoneCalls === 0 &&
                size > 0 && samples.some(sample => Math.abs(sample) > 0.05);
            }
            """, arguments: [:], in: nil, in: .page) { answer in
                switch answer {
                case .success(let value): result = value as? Bool ?? false
                case .failure(let error):
                    print("Website audio fixture failed: \(error.localizedDescription)")
                    result = false
                }
            }
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.20))
        let point = NSPoint(x: 150, y: 60)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: 1) else { return false }
            panel.sendEvent(event)
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        let deadline = Date.now.addingTimeInterval(8)
        while result == nil && Date.now < deadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.04)) }
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))
        if result != true || !fixture.stopped {
            var phase: String?
            view.evaluateJavaScript("globalThis.fixturePhase ?? 'not started'") { value, _ in phase = value as? String }
            let logDeadline = Date.now.addingTimeInterval(1)
            while phase == nil && Date.now < logDeadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.04)) }
            print("Website audio fixture: \(phase ?? "no response"), stop received: \(fixture.stopped)")
        }
        return result == true && fixture.stopped
    }

    private final class DictationTestPage: WKWebView {
        private var simulatedCapture: WKMediaCaptureState = .none
        override var microphoneCaptureState: WKMediaCaptureState { simulatedCapture }

        func simulateCapture(_ state: WKMediaCaptureState) {
            willChangeValue(forKey: "microphoneCaptureState")
            simulatedCapture = state
            didChangeValue(forKey: "microphoneCaptureState")
        }

        override func setMicrophoneCaptureState(_ state: WKMediaCaptureState, completionHandler: (@MainActor () -> Void)? = nil) {
            simulateCapture(state)
            completionHandler?()
        }
    }

    static func runPanelSelfTest() -> Bool {
        _ = NSApplication.shared
        let suite = "dev.quickchat.omni.panel-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = FloatChatController(preferences: defaults)
        let panel = FloatChatPanel(contentRect: NSRect(origin: .zero, size: FloatChatPanel.defaultSize))
        let stack = NSStackView()
        panel.contentView = stack
        controller.panel = panel
        controller.contentStack = stack
        stack.wantsLayer = true
        defer {
            controller.tearDown()
            defaults.removePersistentDomain(forName: suite)
        }

        print("Checking marked text")
        let composer = NSTextView()
        composer.isRichText = false
        stack.addArrangedSubview(composer)
        var dismissals = 0
        panel.onCancel = { dismissals += 1 }
        guard panel.makeFirstResponder(composer) else { return false }
        composer.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        guard composer.hasMarkedText() else { return false }
        panel.cancelOperation(nil)
        guard dismissals == 0 else { return false }
        composer.unmarkText()
        panel.cancelOperation(nil)
        guard dismissals == 1 else { return false }

        print("Checking copy and paste")
        let draft = "FloatChat 测试"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        composer.string = draft
        composer.setSelectedRange(NSRange(location: 0, length: draft.utf16.count))
        guard composer.writeSelection(to: pasteboard, types: composer.writablePasteboardTypes),
              pasteboard.string(forType: .string) == draft else {
            print("Copy did not write the selection")
            return false
        }
        composer.string = ""
        composer.setSelectedRange(NSRange(location: 0, length: 0))
        guard composer.readSelection(from: pasteboard), composer.string == draft else {
            print("Paste did not restore the selection")
            return false
        }
        stack.removeArrangedSubview(composer)
        composer.removeFromSuperview()

        print("Checking WebKit setup")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        controller.configureScripts(config.userContentController)
        let original = WKWebView(frame: .zero, configuration: config)
        let alternate = WKWebView(frame: .zero, configuration: config)
        defaults.set(true, forKey: "glassEnabled")
        controller.applySurfaceAppearance()
        guard let legacyAlpha = stack.layer?.backgroundColor?.alpha,
              abs(legacyAlpha - 0.84) < 0.001, stack.alphaValue == 1, original.alphaValue == 1 else { return false }
        controller.setPanelTranslucency(32)
        guard let sliderAlpha = stack.layer?.backgroundColor?.alpha, abs(sliderAlpha - 0.68) < 0.001 else { return false }
        controller.setPanelTranslucency(0)
        guard stack.layer?.backgroundColor?.alpha == 1, stack.alphaValue == 1 else { return false }
        let first = controller.selectedIndex
        let firstKey = controller.providers[first].key
        let secondKey = controller.providers[1].key
        controller.parkedPages[firstKey] = ParkedPage(view: original, parkedAt: .now, isPinned: false)
        controller.parkedPages[secondKey] = ParkedPage(view: alternate, parkedAt: .now, isPinned: false)
        panel.makeKeyAndOrderFront(nil)
        controller.attachSelectedPage()
        guard controller.webView === original, panel.isVisible else { return false }

        print("Checking fixture load")
        let fixture = "<form onsubmit='sent++; return false'><textarea id='draft'></textarea><button>Send</button></form><script>let sent = 0;</script>"
        original.loadHTMLString(fixture, baseURL: URL(string: "https://chatgpt.com/"))
        alternate.loadHTMLString(fixture, baseURL: nil)
        func evaluate(_ script: String, in page: WKWebView, world: WKContentWorld = .page) -> String? {
            var result: String?
            var done = false
            page.evaluateJavaScript(script, in: nil, in: world) { outcome in
                if case .success(let value) = outcome { result = value as? String }
                done = true
            }
            let deadline = Date.now.addingTimeInterval(5)
            while !done && Date.now < deadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.05)) }
            return result
        }
        let deadline = Date.now.addingTimeInterval(10)
        while (original.isLoading || alternate.isLoading) && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        let value = "document.querySelector('#draft').value + ':' + sent"
        func typeTestKey() -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
                isARepeat: false, keyCode: 12) else { return false }
            panel.sendEvent(event)
            return true
        }
        func waitForValue(_ expected: String, in page: WKWebView, script: String? = nil) -> Bool {
            let deadline = Date.now.addingTimeInterval(3)
            repeat {
                if evaluate(script ?? value, in: page) == expected { return true }
                RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
            } while Date.now < deadline
            return false
        }
        controller.focusSelectedPage()
        let writingPreferences = """
            const field = document.querySelector('#draft');
            field.focus();
            ['autocorrect', 'autocapitalize', 'writingsuggestions'].map(name => field.getAttribute(name)).join(':')
            """
        guard waitForValue("off:off:false", in: original, script: writingPreferences) else { return false }
        guard evaluate("document.querySelector('#draft').value = '测试草稿'", in: original) == "测试草稿" else { return false }
        controller.selectProvider(1)
        guard controller.webView === alternate,
              typeTestKey(), waitForValue("q:0", in: alternate),
              evaluate(value, in: original) == "测试草稿:0" else { return false }
        print("Checking keyboard delivery after switching back")
        controller.selectProvider(first)
        guard controller.webView === original,
              typeTestKey(), waitForValue("测试草稿q:0", in: original),
              evaluate(value, in: alternate) == "q:0" else { return false }

        print("Checking translucency after a client-side conversation layout change")
        if original.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            controller.setPanelTranslucency(32)
            let layout = """
                <main id="canvas" style="position:fixed;inset:0;background-color:rgb(20,30,40)">
                  <h1>New chat</h1><section><p id="stream"></p></section>
                </main>
                <footer id="foot" style="position:fixed;inset:auto 0 0;height:105px;background-color:rgb(45,50,55)">
                  <textarea id="composer" style="display:block;margin:6px auto;width:90%;background-color:rgb(60,65,70)">Sample</textarea>
                </footer>
                """
            let encodedLayout = String(decoding: try! JSONEncoder().encode(layout), as: UTF8.self)
            let background = """
                ['#canvas', '#foot', '#composer'].map(selector => getComputedStyle(document.querySelector(selector)).backgroundColor)
                    .concat(getComputedStyle(document.querySelector('#composer')).opacity).join(':')
                """
            let translucent = "rgba(0, 0, 0, 0):rgba(0, 0, 0, 0):rgb(60, 65, 70):1"
            guard evaluate("document.body.insertAdjacentHTML('beforeend', \(encodedLayout)); 'done'", in: original) == "done",
                  waitForValue(translucent, in: original, script: background) else { return false }

            let replacement = """
                document.querySelector('#canvas').remove();
                document.querySelector('#foot').remove();
                document.body.insertAdjacentHTML('beforeend', \(encodedLayout));
                'done'
                """
            guard evaluate(replacement, in: original) == "done",
                  waitForValue(translucent, in: original, script: background) else { return false }

            print("Checking a Claude-style inset composer backdrop")
            let insetLayout = """
                const footer = document.querySelector('#foot');
                footer.style.inset = 'auto 8px 8px';
                footer.innerHTML = '<div id="card" style="position:absolute;inset:0;background:rgb(50,55,60);border-radius:14px">'
                    + footer.innerHTML + '</div>';
                'done'
                """
            let insetBackground = "getComputedStyle(document.querySelector('#card')).backgroundColor + ':' + (" + background + ")"
            guard evaluate(insetLayout, in: original) == "done",
                  waitForValue("rgb(50, 55, 60):" + translucent, in: original, script: insetBackground)
                  else { return false }

            print("Checking a composer backing strip above the bottom edge")
            let backing = """
                const strip = document.querySelector('#foot');
                strip.style.inset = 'auto 8px 60px';
                strip.style.backgroundImage = 'linear-gradient(#111, #222)';
                document.querySelector('#composer').id = 'prompt-textarea';
                'ready'
                """
            let backingPaint = """
                [getComputedStyle(document.querySelector('#foot')).backgroundImage,
                 getComputedStyle(document.querySelector('#card')).backgroundColor,
                 getComputedStyle(document.querySelector('#prompt-textarea')).opacity].join(':')
                """
            guard evaluate(backing, in: original) == "ready",
                  waitForValue("none:rgb(50, 55, 60):1", in: original, script: backingPaint),
                  evaluate("document.querySelector('#prompt-textarea').id = 'composer'; document.querySelector('#foot').style.inset = 'auto 8px 8px'; 'reset'", in: original) == "reset"
                  else { return false }

            print("Checking ChatGPT's non-hit-testable composer backdrop")
            let footerPaint = """
                <style>
                  [data-thread-scroll-footer] { background: rgb(17,17,17); }
                  [data-thread-scroll-footer]::after {
                    content: ''; position: absolute; inset: 0; pointer-events: none;
                    background-image: linear-gradient(transparent, rgb(17,17,17));
                  }
                </style>
                <div data-thread-scroll-footer=""
                     style="position:fixed;inset:auto 0 0;height:44px;pointer-events:none"></div>
                """
            let encodedFooterPaint = String(decoding: try! JSONEncoder().encode(footerPaint), as: UTF8.self)
            let paintStyle = """
                (() => {
                    const footer = document.querySelector('[data-thread-scroll-footer]');
                    return [getComputedStyle(footer).backgroundColor, getComputedStyle(footer, '::after').backgroundImage].join(':');
                })()
                """
            guard evaluate("document.body.insertAdjacentHTML('beforeend', \(encodedFooterPaint)); 'done'", in: original) == "done",
                  waitForValue("rgba(0, 0, 0, 0):none", in: original, script: paintStyle),
                  evaluate(insetBackground, in: original) == "rgb(50, 55, 60):" + translucent
                  else { return false }

            print("Checking a drawer over a split page")
            let paneMarkup = """
                <aside id="drawer" style="position:fixed;inset:0 auto 0 0;width:45%;background-color:rgb(30,40,50)">
                    <button style="background-color:rgb(60,65,70)">New chat</button>
                </aside>
                <section id="mainPane" style="position:fixed;inset:0 0 0 45%;background-color:rgb(35,45,55)"></section>
                """
            let encodedPanes = String(decoding: try! JSONEncoder().encode(paneMarkup), as: UTF8.self)
            let paneStyle = """
                [getComputedStyle(document.querySelector('#drawer')).backgroundColor.endsWith(', 0.94)'),
                    getComputedStyle(document.querySelector('#drawer')).backdropFilter]
                    .concat(['#mainPane', '#drawer button'].map(selector => getComputedStyle(document.querySelector(selector)).backgroundColor),
                            getComputedStyle(document.querySelector('#drawer button')).opacity,
                            document.querySelector('#drawer').hasAttribute('data-floatchat-drawer'),
                            document.querySelector('#mainPane').hasAttribute('data-floatchat-drawer')).join(':')
                """
            guard evaluate("document.body.insertAdjacentHTML('beforeend', \(encodedPanes)); 'done'", in: original) == "done",
                  waitForValue("true:none:rgba(0, 0, 0, 0):rgb(60, 65, 70):1:true:false", in: original, script: paneStyle)
                  else { return false }
            guard evaluate("document.querySelector('#drawer').remove(); document.querySelector('#mainPane').remove(); 'done'", in: original) == "done",
                  waitForValue(translucent, in: original, script: background) else { return false }
            // Let the coalesced layout update from closing the drawer finish before measuring streaming.
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))

            print("Checking that streaming text does not resample the page surfaces")
            let instrument = """
                globalThis.fixtureSurfaceReads = 0;
                const actualHitTest = document.elementsFromPoint.bind(document);
                document.elementsFromPoint = (...args) => {
                    globalThis.fixtureSurfaceReads++;
                    return actualHitTest(...args);
                };
                'ready'
                """
            guard evaluate(instrument, in: original, world: .defaultClient) == "ready",
                  evaluate("for (let i = 0; i < 100; i++) document.querySelector('#stream').append('x'); 'done'", in: original) == "done"
                  else { return false }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
            guard evaluate("String(globalThis.fixtureSurfaceReads)", in: original, world: .defaultClient) == "0" else { return false }

            print("Checking document-start translucency after navigation and reload")
            let freshDocument = """
                <body style="background-color:rgb(20,30,40)">
                    <footer id="thread-bottom-container" style="background-color:rgb(17,17,17)">
                        <textarea id="draft" style="background-color:rgb(60,65,70)">Sample</textarea>
                    </footer>
                    <script>
                        document.body.dataset.firstPaint = [getComputedStyle(document.body).backgroundColor,
                            getComputedStyle(document.querySelector('footer')).backgroundColor,
                            getComputedStyle(document.querySelector('textarea')).opacity].join(':');
                    </script>
                </body>
                """
            // Use the parked view so the active-page sampler cannot satisfy this check.
            let sample = "document.body.dataset.firstPaint"
            let clearCanvas = "rgba(0, 0, 0, 0):rgba(0, 0, 0, 0):1"
            alternate.loadHTMLString(freshDocument, baseURL: URL(string: "https://chatgpt.com/c/fixture"))
            guard waitForValue(clearCanvas, in: alternate, script: sample) else {
                print("Missing initial ChatGPT styles in the new document")
                return false
            }
            // A file-backed fixture can reload without a network request.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).html")
            defer { try? FileManager.default.removeItem(at: file) }
            guard (try? freshDocument.write(to: file, atomically: true, encoding: .utf8)) != nil else { return false }
            alternate.loadFileURL(file, allowingReadAccessTo: file)
            let clearRoot = "rgba(0, 0, 0, 0):rgb(17, 17, 17):1"
            guard waitForValue(clearRoot, in: alternate, script: sample),
                  evaluate("delete document.body.dataset.firstPaint; 'cleared'", in: alternate) == "cleared" else { return false }
            alternate.reload()
            guard waitForValue(clearRoot, in: alternate, script: sample) else {
                print("Missing initial page styles after reloading the local fixture")
                return false
            }

            controller.setPanelTranslucency(0)
            guard waitForValue("rgb(20, 30, 40):rgb(45, 50, 55):rgb(60, 65, 70):1", in: original, script: background)
                  else { return false }
            guard evaluate(paintStyle, in: original)?.hasPrefix("rgb(17, 17, 17):linear-gradient(") == true
                  else { return false }
        }

        if Self.canClearWebBackground {
            print("Checking a split layout with a late, separate composer backdrop")
            controller.setPanelTranslucency(32)
            for (host, editorAttributes) in [
                ("chatgpt.com", "id='prompt-textarea' contenteditable='true'"),
                ("claude.ai", "class='ProseMirror' contenteditable='true'")
            ] {
                original.loadHTMLString("""
                    <style>
                        #liveHeader::after, #card::before {
                            content: ''; position: absolute; inset: 0; pointer-events: none;
                            background: linear-gradient(#111,#222); box-shadow: 0 0 14px #000;
                        }
                        #card::after { content: 'Hint'; position: absolute; bottom: 0; right: 0; }
                    </style>
                    <header id="liveHeader" style="position:fixed;inset:8px 0 auto;height:40px;
                        background:linear-gradient(#000,#111);box-shadow:0 10px 40px #000">
                        <button style="background:rgb(44,45,46)">Conversation</button>
                    </header>
                    <main style="position:fixed;inset:0 32% 0 0;pointer-events:none">
                      <article style="position:absolute;inset:70px 0 auto;height:100px;background:rgb(36,37,38)">
                        <div style="background:rgb(26,27,28)">An answer with a card</div>
                      </article>
                      <div id="dock" style="position:absolute;inset:auto 0 0;height:125px;pointer-events:auto">
                        <div id="card" style="position:relative;width:100%;height:72px;border-radius:20px;background:rgb(50,55,60)">
                          <div \(editorAttributes)>Reply</div>
                        </div>
                        <button>Attach</button><button>Send</button>
                      </div>
                    </main>
                    """, baseURL: URL(string: "https://\(host)/c/fixture"))
                guard waitForValue("ready", in: original, script: "document.querySelector('#dock') ? 'ready' : ''"),
                      evaluate("""
                          const dock = document.querySelector('#dock');
                          dock.insertAdjacentHTML('afterbegin', '<div><div><div id="new-band" aria-hidden="true" style="position:absolute;inset:0;pointer-events:none;backdrop-filter:blur(10px);box-shadow:0 0 0 12px #000;background:linear-gradient(#181818,#222)"></div></div></div>');
                          'shown'
                          """, in: original) == "shown" else { return false }
                let paint = """
                    [getComputedStyle(document.querySelector('#new-band')).backgroundImage,
                     getComputedStyle(document.querySelector('#new-band')).backdropFilter,
                     getComputedStyle(document.querySelector('#new-band')).boxShadow,
                     getComputedStyle(document.querySelector('#card')).backgroundColor,
                     getComputedStyle(document.querySelector('[contenteditable]')).opacity].join(':')
                    """
                guard waitForValue("none:none:none:rgb(50, 55, 60):1", in: original, script: paint) else { return false }
                let generatedPaint = """
                    [getComputedStyle(document.querySelector('#liveHeader')).backgroundImage,
                     getComputedStyle(document.querySelector('#liveHeader'), '::after').backgroundImage,
                     getComputedStyle(document.querySelector('#card'), '::before').backgroundImage,
                     getComputedStyle(document.querySelector('#card'), '::after').content,
                     getComputedStyle(document.querySelector('header button')).backgroundColor,
                     getComputedStyle(document.querySelector('article')).backgroundColor].join(':')
                    """
                guard waitForValue("none:none:none:\"Hint\":rgb(44, 45, 46):rgb(36, 37, 38)",
                                   in: original, script: generatedPaint) else { return false }
                if host == "chatgpt.com" {
                    let portal = """
                        document.body.insertAdjacentHTML('beforeend',
                            '<div aria-hidden="true" style="pointer-events:none"><div id="bottom-portal" style="position:fixed;left:18px;right:18px;bottom:-4px;height:23px;background:rgb(18,18,18)"></div></div>');
                        'ready'
                        """
                    let portalColor = "getComputedStyle(document.querySelector('#bottom-portal')).backgroundColor"
                    guard evaluate(portal, in: original) == "ready",
                          waitForValue("rgba(0, 0, 0, 0)", in: original, script: portalColor) else { return false }
                }
                controller.setPanelTranslucency(0)
                let restorePaint = """
                    String(['#liveHeader', '#card'].every((selector, index) =>
                        getComputedStyle(document.querySelector(selector), index ? '::before' : '::after')
                            .backgroundImage.startsWith('linear-gradient(')))
                    """
                guard waitForValue("true", in: original, script: restorePaint) else { return false }
                controller.setPanelTranslucency(32)
            }
            controller.setPanelTranslucency(0)
        }

        print("Checking native website editor field layout")
        let editor = NSAlert()
        editor.messageText = "Edit Website"
        editor.addButton(withTitle: "Save")
        let name = NSTextField(string: "ChatGPT")
        let address = NSTextField(string: "https://chatgpt.com/")
        editor.accessoryView = websiteEditorFields([name, address])
        editor.layout()
        guard name.frame.width >= 290, address.frame.width == name.frame.width,
              name.frame.minY > address.frame.maxY else { return false }

        print("Checking independent Settings and chat windows")
        defaults.set(true, forKey: "hideOnClickAway")
        controller.showSettings()
        guard let settings = controller.settingsWindow, settings.isVisible, panel.isVisible,
              controller.webView === original else { return false }
        controller.show()
        guard settings.isVisible, panel.isVisible else { return false }
        settings.close()
        guard panel.isVisible else { return false }

        print("Checking hide and retain")
        controller.hide(restoreFocus: false)
        guard controller.webView == nil, !panel.isVisible,
              controller.parkedPages[firstKey]?.view === original else { return false }
        controller.selectProvider(1)
        guard controller.webView == nil else { return false }
        print("Checking parked failure")
        let failed = controller.providers[1].url.appendingPathComponent("retry")
        controller.pageFailed(alternate, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: failed]))
        panel.orderFrontRegardless()
        controller.attachSelectedPage()
        guard controller.webView === alternate, controller.failureURL == failed else { return false }
        controller.offline = true
        guard controller.retryURL == failed else { return false }
        controller.offline = false
        controller.failureURL = nil
        guard controller.retryURL == nil else { return false }
        print("Checking immediate release")
        controller.setRetention(0, forPinned: false)
        controller.hide(restoreFocus: false)
        guard controller.webView == nil, controller.parkedPages.isEmpty,
              controller.evictionTimer == nil else { return false }

        print("Checking that a pin restores its saved conversation")
        guard let fixtureURL = original.url else { return false }
        var pin = Provider(name: "Fixture", url: fixtureURL)
        pin.sessionID = "pinned-test"
        pin.pinned = true
        pin.conversationURL = fixtureURL
        controller.parkedPages[pin.key] = ParkedPage(view: original, parkedAt: .now, isPinned: true)
        guard controller.takeParkedPage(for: pin)?.view === original else { return false }
        pin.conversationURL = fixtureURL.appendingPathComponent("saved-conversation")
        controller.parkedPages[pin.key] = ParkedPage(view: original, parkedAt: .now, isPinned: true)
        guard controller.takeParkedPage(for: pin) == nil else { return false }

        print("Checking draft isolation and restore after a fresh document")
        let draftView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), configuration: config)
        let conversation = URL(string: "https://chatgpt.com/c/private-fixture")!
        let editorMarkup = "<textarea id='prompt-textarea'></textarea><button data-testid='stop-button'>Stop</button>"
        draftView.loadHTMLString(editorMarkup, baseURL: conversation)
        let draftValue = "document.querySelector('#prompt-textarea')?.value"
        guard waitForValue("", in: draftView, script: draftValue),
              evaluate("document.querySelector('textarea').value = 'local draft'", in: draftView) == "local draft",
              evaluate("String(" + GenerationIndicator.generating + ")", in: draftView) == "true",
              evaluate("document.querySelector('button').remove(); String(" + GenerationIndicator.generating + ")", in: draftView) == "false"
              else { return false }
        let drafts = PinnedDrafts()
        drafts.capture(draftView, key: "one", url: conversation)
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
        draftView.loadHTMLString(editorMarkup, baseURL: conversation)
        guard waitForValue("", in: draftView, script: draftValue) else { return false }
        drafts.restore(draftView, key: "other-pin", url: conversation)
        guard evaluate(draftValue, in: draftView) == "" else { return false }
        drafts.restore(draftView, key: "one", url: conversation)
        guard waitForValue("local draft", in: draftView, script: draftValue),
              evaluate("document.querySelector('textarea').value = 'website draft'", in: draftView) == "website draft"
              else { return false }
        drafts.restore(draftView, key: "one", url: conversation)
        guard evaluate(draftValue, in: draftView) == "website draft" else { return false }

        print("Checking concurrent replies and delayed stop controls")
        let other = WKWebView(frame: draftView.frame, configuration: config)
        let controls = """
            <div id="shell" style="display:none">
              <form><textarea id="prompt-textarea"></textarea><button aria-label="Stop">Stop</button></form>
            </div>
            """
        other.loadHTMLString(controls, baseURL: URL(string: "https://example.com/chat"))
        guard waitForValue("ready", in: other, script: "document.querySelector('button') ? 'ready' : ''"),
              evaluate("String(" + GenerationIndicator.generating + ")", in: other) == "false" else { return false }
        let indicator = GenerationIndicator()
        defer { indicator.stop() }
        indicator.watch(draftView, key: "pinned")
        indicator.watch(other, key: "custom")
        RunLoop.current.run(until: Date.now.addingTimeInterval(2.2))
        guard indicator.generatingKeys == ["pinned"], indicator.isWatching(other),
              evaluate("document.querySelector('#shell').style.display = 'block'; 'started'", in: other) == "started"
              else { return false }
        let startDeadline = Date.now.addingTimeInterval(3)
        while indicator.generatingKeys.count < 2 && Date.now < startDeadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        guard indicator.generatingKeys == ["pinned", "custom"], indicator.mostRecentKey == "custom",
              evaluate("document.querySelector('button').remove(); 'finished'", in: other) == "finished" else { return false }
        let endDeadline = Date.now.addingTimeInterval(3.5)
        while indicator.isWatching(other) && Date.now < endDeadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        guard indicator.generatingKeys == ["pinned"], !indicator.isWatching(other) else { return false }
        indicator.stopWatching(draftView)
        guard indicator.generatingKeys.isEmpty else { return false }

        print("Checking recording filenames and explicit upload picker navigation")
        let recordings = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recordings) }
        do { try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false) }
        catch { return false }
        let firstRecording = MeetingRecorder.recordingURL(in: recordings)
        let anotherRecording = MeetingRecorder.recordingURL(in: recordings)
        guard firstRecording != anotherRecording, firstRecording.pathExtension == "m4a",
              firstRecording.deletingLastPathComponent().path == recordings.path else { return false }
        do { try Data([0]).write(to: anotherRecording) } catch { return false }
        let picker = NSOpenPanel()
        let shortcut = RecordingPickerShortcut(picker: picker, directory: recordings)
        picker.accessoryView = shortcut
        shortcut.performClick(nil)
        guard picker.directoryURL?.resolvingSymlinksInPath().path == recordings.resolvingSymlinksInPath().path,
              picker.urls.isEmpty else { return false }

        print("Checking an optional Downloads copy keeps existing files")
        let downloads = recordings.appendingPathComponent("Downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
            let existing = downloads.appendingPathComponent(anotherRecording.lastPathComponent)
            try Data([1]).write(to: existing)
            let copy = try Self.copyRecording(anotherRecording, to: downloads)
            guard copy.path != existing.path, try Data(contentsOf: copy) == Data([0]),
                  try Data(contentsOf: existing) == Data([1]),
                  try Data(contentsOf: anotherRecording) == Data([0]) else { return false }
        } catch { return false }

        print("Checking automatic attachment to the original parked chat")
        let receivingPage = WKWebView(frame: draftView.frame, configuration: config)
        let receivingURL = URL(string: "https://chatgpt.com/c/recording-fixture")!
        let key = controller.providers[controller.selectedIndex].key
        let source = ChatRecording(key: key, view: receivingPage, url: receivingURL)
        controller.webView = receivingPage
        receivingPage.uiDelegate = controller
        controller.recordingChat = source
        stack.addArrangedSubview(receivingPage)
        panel.orderFrontRegardless()
        receivingPage.loadHTMLString("""
            <form onsubmit="window.sent = true; return false">
              <input type="file" accept="image/*">
              <input id="audio" type="file" accept="audio/*">
              <textarea id="prompt-textarea"></textarea>
            </form>
            <script>
              document.querySelector('#audio').addEventListener('change', async event => {
                window.receivedByte = new Uint8Array(await event.target.files[0].arrayBuffer())[0];
              });
            </script>
            """, baseURL: receivingURL)
        guard waitForValue("ready", in: receivingPage, script: "document.querySelector('#audio') ? 'ready' : ''"),
              !source.matches(other, key: key), !source.matches(receivingPage, key: "a-different-tab") else { return false }
        panel.orderOut(nil)
        controller.parkActivePage()
        guard controller.webView == nil, controller.parkedPages[key]?.view === receivingPage else { return false }
        controller.recordingDidSave(anotherRecording, automaticallyAttach: true)
        let handoff = "String(document.querySelector('#audio').files.length) + ':' + String(window.receivedByte) + ':' + String(window.sent === true) + ':' + document.querySelector('textarea').value"
        guard waitForValue("1:0:false:" + AppText.t("Please transcribe this audio recording."), in: receivingPage, script: handoff),
              !panel.isVisible, source.didHandOff, source.attachmentConfirmed else { return false }
        controller.show()
        guard controller.webView === receivingPage,
              evaluate("history.replaceState({}, '', '/c/different'); 'changed'", in: receivingPage) == "changed",
              !source.matches(receivingPage, key: key), source.didHandOff else { return false }

        print("Checking unsupported audio pickers leave the recording available to save")
        guard let currentURL = receivingPage.url,
              evaluate("document.querySelector('#audio').remove(); 'ready'", in: receivingPage) == "ready" else { return false }
        let unsupported = ChatRecording(key: key, view: receivingPage, url: currentURL)
        controller.recordingChat = unsupported
        controller.recordingDidSave(anotherRecording, automaticallyAttach: true)
        let attachmentDeadline = Date.now.addingTimeInterval(3)
        while !unsupported.attachmentFailed && Date.now < attachmentDeadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        guard unsupported.attachmentFailed, !unsupported.attachmentConfirmed,
              controller.lastRecordingFile == anotherRecording else { return false }

        print("Checking temporary recordings expire without touching recent or unrelated files")
        let stale = firstRecording
        let unrelated = recordings.appendingPathComponent("Unrelated.m4a")
        do {
            try Data([0]).write(to: stale)
            try Data([0]).write(to: unrelated)
            let past = Date.now.addingTimeInterval(-MeetingRecorder.stagingLifetime - 60)
            for file in [stale, unrelated] {
                try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
            }
            MeetingRecorder.removeExpiredStaging(in: recordings)
            guard !FileManager.default.fileExists(atPath: stale.path),
                  FileManager.default.fileExists(atPath: unrelated.path),
                  FileManager.default.fileExists(atPath: anotherRecording.path) else { return false }
        } catch { return false }

        print("Checking website dictation survives the window’s minimize action")
        controller.hide(restoreFocus: false)
        let dictationPage = DictationTestPage(frame: draftView.frame, configuration: config)
        controller.setRetention(10, forPinned: false)
        controller.parkedPages[key] = ParkedPage(view: dictationPage, parkedAt: .now, isPinned: false)
        controller.show()
        guard controller.webView === dictationPage else { return false }
        controller.setRetention(0, forPinned: false)
        panel.onCancel = { [weak controller] in controller?.hide(restoreFocus: false) }
        dictationPage.simulateCapture(.active)
        guard let minimize = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                              timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                              characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46),
              panel.performKeyEquivalent(with: minimize) else { return false }
        guard !panel.isVisible, controller.webView === dictationPage, dictationPage.window === panel,
              dictationPage.microphoneCaptureState == .active, controller.meetingRecorder.isIndicatorVisible else { return false }
        dictationPage.simulateCapture(.none)
        guard controller.hiddenMicrophoneGrace != nil, !controller.meetingRecorder.isIndicatorVisible,
              controller.webView === dictationPage else { return false }
        controller.show()
        guard panel.isVisible, controller.webView === dictationPage,
              controller.hiddenMicrophoneGrace == nil else { return false }

        print("Checking the recording overlay leaves the chat layout in place")
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        let page = NSView(frame: canvas.bounds)
        canvas.addSubview(page)
        let overlay = RecordingOverlay(target: NSApp, action: #selector(NSApplication.stop(_:)))
        canvas.addSubview(overlay, positioned: .above, relativeTo: page)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 8),
            overlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -10)
        ])
        guard overlay.isHidden else { return false }
        overlay.display("Recording", recording: true, action: "Stop")
        canvas.layoutSubtreeIfNeeded()
        guard !overlay.isHidden, overlay.frame.width > 60, canvas.bounds.contains(overlay.frame), page.frame == canvas.bounds else { return false }
        overlay.display(nil)
        guard overlay.isHidden, page.frame == canvas.bounds else { return false }

        print("Checking frame recovery")
        panel.setFrameOrigin(NSPoint(x: 60_000, y: 60_000))
        controller.keepPanelReachable(panel)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return false }
        print("Panel checks passed: marked text, copy and paste, WebKit draft retention, switching, hide and expiry, parked failure, off-screen recovery")
        return true
    }

    static func runCacheSelfTest() -> Bool {
        _ = NSApplication.shared
        guard ProviderAddress.matchesWebsite(host: "perplexity.ai", baseHost: "www.perplexity.ai"),
              !ProviderAddress.matchesWebsite(host: "chatgpt.com.evil.example", baseHost: "chatgpt.com"),
              !ProviderAddress.matchesWebsite(host: "notchatgpt.com", baseHost: "chatgpt.com") else { return false }
        let suite = "dev.quickchat.omni.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatChatController(preferences: defaults)
        let selected = controller.chatURL
        defaults.set("zh-Hans", forKey: "appLanguage")
        guard controller.pageRequest(selected).value(forHTTPHeaderField: "Accept-Language") == "zh-CN,zh;q=0.9" else { return false }
        defaults.set("en", forKey: "appLanguage")
        guard controller.pageRequest(selected).value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9" else { return false }
        controller.reorderProviders(IndexSet(integer: 0), to: 3)
        guard controller.chatURL == selected, controller.providers[2].url == selected else { return false }
        let restored = FloatChatController(preferences: defaults)
        guard restored.providers[2].url == selected else { return false }
        guard controller.addWebsite("Example", address: "EXAMPLE.com", fetchIcon: false),
              !controller.addWebsite("Duplicate", address: "https://example.com:443/"),
              !controller.addWebsite("Unsafe", address: "http://example.net/"),
              !controller.addWebsite("Credentials", address: "https://user:secret@example.net/") else { return false }
        guard ProviderAddress.parse(" https://EXAMPLE.com:443 ")?.absoluteString == "https://example.com/" else { return false }
        let custom = controller.providers.firstIndex(where: { $0.url.host == "example.com" })!
        controller.deleteProvider(custom)
        guard !controller.providers.contains(where: { $0.url.host == "example.com" }), controller.chatURL == selected else { return false }
        let before = controller.providers.count
        controller.deleteProvider(controller.selectedIndex)
        guard controller.providers.count == before - 1, controller.chatURL != selected else { return false }
        guard controller.addWebsite("ChatGPT", address: selected.absoluteString, fetchIcon: false) else { return false }
        let first = controller.providers.firstIndex(where: { $0.url == selected })!
        controller.toggleProvider(first)
        guard controller.chatURL != selected else { return false }
        controller.toggleProvider(first)
        let sample = controller.providers[controller.selectedIndex]
        guard !controller.canRemember(sample.url.appendingPathComponent("sign_in"), provider: sample),
              !controller.canRemember(URL(string: sample.url.absoluteString + "?access_token=test")!, provider: sample) else { return false }
        let instantKey = controller.providers[controller.selectedIndex].key
        let sessionURL = controller.providers[controller.selectedIndex].url.appendingPathComponent("c/test-conversation")
        controller.togglePin(url: sessionURL, title: "A pinned test conversation")
        guard controller.savedSessions.count == 1 else { return false }
        let pinnedKey = controller.providers[controller.selectedIndex].key
        guard pinnedKey != instantKey else { return false }
        let pinProvider = controller.providers[controller.selectedIndex]
        controller.setZoom(1.5, for: pinnedKey)
        controller.setZoom(1.1, for: instantKey)
        guard controller.zoom(for: pinProvider) == 1.5,
              controller.zoom(for: sample) == 1.1,
              !controller.canRemember(URL(string: sample.url.absoluteString + "#access_token=test")!, provider: sample),
              controller.providers.contains(where: { $0.url == Self.doubaoURL }) else { return false }
        controller.rememberPinnedTitle("A different page", at: sessionURL.appendingPathComponent("other"), for: pinnedKey)
        controller.rememberPinnedTitle("\(sample.name): The saved topic", at: sessionURL, for: pinnedKey)
        controller.rememberPinnedTitle(sample.name, at: sessionURL, for: pinnedKey)
        controller.rememberPinnedTitle("New chat", at: sessionURL, for: pinnedKey)
        let persisted = FloatChatController(preferences: defaults)
        guard let savedPin = persisted.providers.first(where: { $0.key == pinnedKey && $0.conversationURL == sessionURL }),
              persisted.preview(for: savedPin) == "The saved topic" else { return false }
        var secondPin = controller.savedSessions[0]
        secondPin.sessionID = UUID().uuidString
        secondPin.topic = "Second pinned conversation"
        controller.savedSessions.append(secondPin)
        controller.saveSessions()
        defaults.set(true, forKey: "pinnedFirst")
        let secondIndex = controller.providers.firstIndex(where: { $0.key == secondPin.key })!
        let firstIndex = controller.providers.firstIndex(where: { $0.key == pinnedKey })!
        controller.reorderProviders(IndexSet(integer: secondIndex), to: firstIndex)
        guard controller.providers[controller.enabledTabIndices[0]].key == secondPin.key,
              controller.providers[controller.selectedIndex].key == pinnedKey else { return false }
        let builtIn = controller.providers.first { $0.url == selected }!
        let orderBeforeEdit = controller.providers.map(\.key)
        let modifiedURL = URL(string: "https://example.org/chat")!
        let builtInIndex = controller.providers.firstIndex { $0.key == builtIn.key }!
        controller.toggleProvider(builtInIndex)
        controller.setZoom(1.25, for: builtIn.key)
        guard !controller.saveWebsiteEdit(builtIn, name: "Duplicate", address: Self.doubaoURL.absoluteString, fetchIcon: false),
              controller.saveWebsiteEdit(builtIn, name: "My ChatGPT", address: modifiedURL.absoluteString, fetchIcon: false),
              controller.providers.map(\.key) == orderBeforeEdit else { return false }
        let editedSettings = FloatChatController(preferences: defaults)
        guard let edited = editedSettings.providers.first(where: { $0.key == builtIn.key }),
              edited.name == "My ChatGPT", edited.url == modifiedURL,
              editedSettings.disabledURLs.contains(edited.key), editedSettings.zoom(for: edited) == 1.25,
              editedSettings.providers.contains(where: { $0.key == pinnedKey && $0.conversationURL == sessionURL }),
              !editedSettings.providers.contains(where: { $0.url == selected }),
              !controller.addWebsite("Duplicate original address", address: selected.absoluteString, fetchIcon: false) else { return false }
        guard controller.saveWebsiteEdit(edited, name: builtIn.name, address: selected.absoluteString, fetchIcon: false) else { return false }
        controller.toggleProvider(builtInIndex)
        let restoredGroups = FloatChatController(preferences: defaults)
        guard restoredGroups.pinnedFirst, restoredGroups.providers[restoredGroups.enabledTabIndices[0]].key == secondPin.key else { return false }
        controller.deleteProvider(controller.providers.firstIndex(where: { $0.key == secondPin.key })!)
        defaults.set(false, forKey: "pinnedFirst")
        guard !controller.providers[controller.enabledTabIndices[0]].isPinned else { return false }
        controller.parkedPages[instantKey] = ParkedPage(view: WKWebView(), parkedAt: .distantPast, isPinned: false)
        controller.parkedPages[pinnedKey] = ParkedPage(view: WKWebView(), parkedAt: .distantPast, isPinned: true)
        controller.prunePages()
        guard controller.chatURL == sessionURL else { return false }
        let hiddenPin = controller.providers.firstIndex(where: { $0.key == pinnedKey })!
        controller.toggleProvider(hiddenPin)
        let beforeUnpin = controller.providers[controller.selectedIndex].key
        controller.unpinProvider(hiddenPin)
        guard controller.savedSessions.isEmpty, controller.providers[controller.selectedIndex].key == beforeUnpin else { return false }
        let now = Date()
        defaults.set(5, forKey: "retentionMinutes")
        guard controller.retentionMinutes(forPinned: true) == 5 else { return false }
        controller.setRetention(1, forPinned: false)
        guard controller.retentionMinutes(forPinned: false) == 1,
              controller.retentionMinutes(forPinned: true) == 5 else { return false }
        for index in 0..<6 {
            controller.parkedPages[String(index)] = ParkedPage(view: WKWebView(), parkedAt: now, isPinned: index == 5)
        }
        controller.prunePages(at: now.addingTimeInterval(59))
        guard controller.parkedPages.count == 6 else { return false }
        controller.prunePages(at: now.addingTimeInterval(60))
        guard Set(controller.parkedPages.keys) == Set(["5"]) else { return false }
        controller.prunePages(at: now.addingTimeInterval(300))
        guard controller.parkedPages.isEmpty, controller.evictionTimer == nil else { return false }
        controller.setRetention(0, forPinned: true)
        controller.parkedPages["immediate"] = ParkedPage(view: WKWebView(), parkedAt: now, isPinned: true)
        controller.prunePages(at: now)
        guard controller.parkedPages.isEmpty, controller.evictionTimer == nil else { return false }
        controller.tearDown()
        print("Checks passed: provider ordering and persistence, URL validation, duplicate rejection, active-provider fallback, deletion and re-adding, independent sessions, pinned URL persistence, group ordering, language headers, unpinning, independent timed retention without a count limit, and immediate release")
        return true
    }
}
#endif

#if DEBUG
extension FloatChatController {
    @MainActor
    private final class LanguageScriptProbe: NSObject, WKNavigationDelegate {
        let controller: FloatChatController
        let defaults: UserDefaults
        let view: WKWebView
        var step = 0
        var finished = false
        var passed = true
        init(controller: FloatChatController, defaults: UserDefaults) {
            self.controller = controller
            self.defaults = defaults
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            controller.configureScripts(config.userContentController)
            view = WKWebView(frame: .zero, configuration: config)
            super.init()
            view.navigationDelegate = self
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("navigator.language") { [weak self] value, error in
                guard let self else { return }
                let expected = self.step == 0 ? "en-US" : "zh-CN"
                guard error == nil, value as? String == expected else {
                    self.passed = false; self.finished = true; return
                }
                if self.step == 0 {
                    self.step = 1
                    self.defaults.set("zh-Hans", forKey: "appLanguage")
                    self.controller.configureScripts(webView.configuration.userContentController)
                    webView.loadHTMLString("<p>Locale check two</p>", baseURL: nil)
                } else { self.finished = true }
            }
        }
    }
    static func runLanguageSelfTest() -> Bool {
        _ = NSApplication.shared
        let suite = "dev.quickchat.omni.locale-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "appLanguage")
        let controller = FloatChatController(preferences: defaults)
        let probe = LanguageScriptProbe(controller: controller, defaults: defaults)
        probe.view.loadHTMLString("<p>Locale check one</p>", baseURL: nil)
        let deadline = Date.now.addingTimeInterval(15)
        while !probe.finished && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        probe.view.stopLoading()
        print("WebKit language checks: English and Chinese = \(probe.finished && probe.passed)")
        return probe.finished && probe.passed
    }
}
#endif
