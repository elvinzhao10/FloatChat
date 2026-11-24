import AppKit
import AVFoundation

/// Captures microphone audio and stages it for the originating website.
@MainActor
final class MeetingRecorder: NSObject, AVAudioRecorderDelegate {
    static let folder = URL.applicationSupportDirectory
        .appendingPathComponent("dev.quickchat.omni/Recordings", isDirectory: true)

    static let stagingFolder = folder.appendingPathComponent("Temporary", isDirectory: true)
    static let stagingLifetime: TimeInterval = 60 * 60
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    var onChange: (() -> Void)?
    var onSaved: ((URL, Bool) -> Void)?
    var isBusy: Bool { requestingPermission || isRecording }
    private var recorder: AVAudioRecorder?
    private var combined: (any CombinedRecording)?
    private var saveURL: URL?
    enum IndicatorAction { case stopRecording, stopCombinedRecording, reopenWebsite, websiteTranscript }

    private var indicator: NSPanel?
    private var indicatorAction: IndicatorAction?
    private var indicatorMeter: Timer?
    private var captureActivity: (any NSObjectProtocol)?
    private var position: NSPoint?
    private var requestingPermission = false
    private var recordingMonitor: Timer?

    var isRecording: Bool { recorder != nil || combined != nil }
    private(set) var lastHadSystemAudio: Bool?
    var recordsSystemAudio: Bool { combined?.includesSystemAudio == true }
    var usesBuiltInMicrophone: Bool { combined?.usesBuiltInMicrophone == true }
    var heardSystemAudio: Bool { combined?.heardSystemAudio == true }
    var systemAudioStatus: String {
        heardSystemAudio ? "System audio detected" : "Waiting for system audio"
    }
    var actionTitle: String { AppText.t(isRecording ? "Stop Recording" : "Record and Attach Audio") }

    func toggle(includeSystemAudio: Bool, preferences: UserDefaults, canStart: @escaping @MainActor () -> Bool = { true }) {
        if isRecording {
            stop()
            return
        }
        guard !requestingPermission else { return }
        requestingPermission = true
        Task { [weak self] in
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed = if status == .notDetermined { await AVCaptureDevice.requestAccess(for: .audio) }
                          else { status == .authorized }
            guard let self, self.requestingPermission else { return }
            self.requestingPermission = false
            guard allowed else {
                self.showMessage("Microphone access is off.", detail: "Allow FloatChat under System Settings → Privacy & Security → Microphone.")
                return
            }
            if includeSystemAudio, !preferences.bool(forKey: "didExplainSystemAudio") {
                guard self.confirmSystemAudio() else { return }
                preferences.set(true, forKey: "didExplainSystemAudio")
            }
            guard canStart() else { return }
            self.start(includeSystemAudio: includeSystemAudio)
        }
    }

    private func start(includeSystemAudio: Bool) {
        do {
            try FileManager.default.createDirectory(at: Self.stagingFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let destination = Self.recordingURL(in: Self.stagingFolder)
            let temporary = Self.stagingFolder.appendingPathComponent("." + destination.lastPathComponent)
            if #available(macOS 14.2, *),
               try includeSystemAudio || CombinedAudioCapture.needsHeadphoneSafeInput() {
                do {
                    combined = try CombinedAudioCapture(url: temporary, includesSystemAudio: includeSystemAudio)
                    saveURL = destination
                    started()
                } catch AudioCaptureError.noSafeMicrophone {
                    try? FileManager.default.removeItem(at: temporary)
                    showMessage("Choose a different microphone.",
                                detail: "Choose a built-in, wired, or USB microphone in System Settings to keep Bluetooth headphone playback available.")
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    guard includeSystemAudio else {
                        showMessage("Couldn’t start recording.", detail: "Check the microphone and available disk space.")
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = AppText.t("System audio couldn’t start.")
                    alert.informativeText = AppText.t("Check FloatChat’s system audio permission in Privacy & Security. You can keep recording with the microphone only.")
                    alert.addButton(withTitle: AppText.t("Record Microphone Only"))
                    alert.addButton(withTitle: AppText.t("Audio Privacy Settings…"))
                    alert.addButton(withTitle: AppText.t("Cancel"))
                    NSApp.activate()
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: start(includeSystemAudio: false)
                    case .alertSecondButtonReturn: Self.openAudioPrivacySettings()
                    default: break
                    }
                }
                return
            }
            let audio = try AVAudioRecorder(url: temporary, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 32_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            audio.delegate = self
            guard audio.record() else {
                try? FileManager.default.removeItem(at: temporary)
                showMessage("Couldn’t start recording.", detail: "Check that a microphone is connected and available.")
                return
            }
            recorder = audio
            saveURL = destination
            started()
        } catch {
            showMessage("Couldn’t start recording.", detail: "Check the microphone and available disk space.")
        }
    }

    private func started() {
        lastHadSystemAudio = nil
        captureActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                               reason: "Recording audio")
        var signaledPlayback = false
        let monitor = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let combined = self.combined, !combined.isRunning {
                    self.finishCombined(interrupted: true, showErrors: true, attach: false)
                } else if let recorder = self.recorder, !recorder.isRecording {
                    self.finish(ObjectIdentifier(recorder), interrupted: true)
                } else if !signaledPlayback, self.heardSystemAudio {
                    signaledPlayback = true
                    self.onChange?()
                }
            }
        }
        monitor.tolerance = 0.4
        recordingMonitor = monitor
        RunLoop.main.add(monitor, forMode: .common)
        onChange?()
    }

    static func recordingURL(in directory: URL, date: Date = .now, id: UUID = UUID()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return directory.appendingPathComponent("Recording \(formatter.string(from: date)) \(id.uuidString.prefix(8)).m4a")
    }

    func stop(showErrors: Bool = true, attachToChat: Bool = true) {
        requestingPermission = false
        if let combined {
            let interrupted = !combined.isRunning
            finishCombined(interrupted: interrupted, showErrors: showErrors, attach: attachToChat && !interrupted)
            return
        }
        guard let recorder else { return }
        let wasRecording = recorder.isRecording
        recorder.stop()
        finish(ObjectIdentifier(recorder), interrupted: !wasRecording, showErrors: showErrors, attach: attachToChat && wasRecording)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.finish(id, interrupted: true) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.finish(id, interrupted: true) }
    }

    private func finish(_ id: ObjectIdentifier, interrupted: Bool, showErrors: Bool = true, attach: Bool = false) {
        guard let audio = recorder, ObjectIdentifier(audio) == id, let destination = saveURL else { return }
        recorder = nil
        audio.delegate = nil
        if audio.isRecording { audio.stop() }
        finishFile(audio.url, destination: destination, interrupted: interrupted, showErrors: showErrors, attach: attach)
    }

    private func finishCombined(interrupted: Bool, showErrors: Bool, attach: Bool) {
        guard let combined, let destination = saveURL else { return }
        self.combined = nil
        combined.stop()
        lastHadSystemAudio = combined.includesSystemAudio ? combined.heardSystemAudio : nil
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent)
        finishFile(temporary, destination: destination, interrupted: interrupted, showErrors: showErrors, attach: attach)
    }

    private func finishFile(_ temporary: URL, destination: URL, interrupted: Bool, showErrors: Bool, attach: Bool) {
        recordingMonitor?.invalidate()
        recordingMonitor = nil
        saveURL = nil
        if let captureActivity { ProcessInfo.processInfo.endActivity(captureActivity) }
        captureActivity = nil
        onChange?()
        do {
            let captured = try AVAudioFile(forReading: temporary)
            guard captured.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            Self.scheduleRemoval(of: destination, after: Self.stagingLifetime) { [weak self] in
                self?.onChange?()
            }
            onSaved?(destination, attach)
            if interrupted, showErrors {
                showMessage("Recording ended early.", detail: "Use Save Last Recording in the FloatChat menu to recover any audio that was captured.")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if showErrors {
                showMessage(interrupted ? "Recording ended early." : "Couldn’t finish saving the recording.",
                            detail: "No audio could be recovered. Check your microphone and available disk space.")
            }
        }
    }

    private static func scheduleRemoval(of file: URL, after delay: TimeInterval,
                                        onRemoval: (@MainActor () -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: file)
            onRemoval?()
        }
    }

    static func latestStagedRecording() -> URL? {
        recordings(in: stagingFolder)
            .filter { !$0.url.lastPathComponent.hasPrefix(".") && Date.now.timeIntervalSince($0.modified) < stagingLifetime }
            .max { $0.modified < $1.modified }?.url
    }

    static func cleanUpStagingFromPreviousLaunch() {
        let now = Date.now
        removeExpiredStaging(now: now)
        for item in recordings(in: stagingFolder) {
            let delay = max(0, stagingLifetime - now.timeIntervalSince(item.modified))
            scheduleRemoval(of: item.url, after: delay)
        }
    }

    static func removeExpiredStaging(in directory: URL = stagingFolder, now: Date = .now) {
        for item in recordings(in: directory) where now.timeIntervalSince(item.modified) >= stagingLifetime {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    static func trashExpiredRecordings() {
        let cutoff = Date.now.addingTimeInterval(-retention)
        for item in recordings(in: folder) where item.modified <= cutoff {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
    }

    private static func recordings(in directory: URL) -> [(url: URL, modified: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.range(of: #"^\.?Recording [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}-[0-9]{2}-[0-9]{2} [A-F0-9]{8}\.m4a$"#,
                             options: .regularExpression) != nil,
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let modified = values.contentModificationDate else { return nil }
            return (url, modified)
        }
    }

    var isIndicatorVisible: Bool { indicator?.isVisible == true }
    private var indicatorContent: RecordingIndicatorContent? { indicator?.contentView as? RecordingIndicatorContent }

    func updateIndicator(near frame: NSRect?, action: IndicatorAction?, websiteLevel: (@MainActor () -> Float)? = nil,
                         offersPreview: Bool = false, preview: DictationPreview.Presentation? = nil,
                         onReopenChat: (() -> Void)? = nil, onWebsitePress: (() -> Void)? = nil) {
        guard let action else {
            indicatorContent?.present(nil)
            indicator?.orderOut(nil)
            indicatorMeter?.invalidate()
            indicatorMeter = nil
            recorder?.isMeteringEnabled = false
            return
        }
        if indicator == nil { indicator = makeIndicator(near: frame) }
        guard let content = indicatorContent else { return }
        let ball = content.ball
        if indicatorAction != action {
            ball.setRecordingActive(action != .websiteTranscript)
            indicatorAction = action
        }
        if action == .reopenWebsite || action == .websiteTranscript {
            let help = AppText.t(offersPreview ? "Show or hide dictation preview. Drag to move."
                                              : "Website dictation is active. Click to reopen the chat.")
            ball.toolTip = help
            ball.setAccessibilityLabel(help)
            ball.onPress = onWebsitePress
            content.onOpenChat = onReopenChat
            content.present(preview)
        } else {
            let help = AppText.t(action == .stopCombinedRecording
                ? "Recording microphone and system audio. Click to stop, or drag to move."
                : "Recording microphone. Click to stop, or drag to move.")
            ball.toolTip = help
            ball.setAccessibilityLabel(help)
            ball.onPress = { [weak self] in self?.stop() }
            content.onOpenChat = nil
            content.present(nil)
        }
        if !isIndicatorVisible { indicator?.orderFrontRegardless() }
        if action == .websiteTranscript {
            indicatorMeter?.invalidate()
            indicatorMeter = nil
            return
        }
        guard isIndicatorVisible, indicatorMeter == nil else { return }
        recorder?.isMeteringEnabled = true
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let ball = self.indicatorContent?.ball else { return }
                let level: Float
                if self.indicatorAction == .reopenWebsite {
                    level = websiteLevel?() ?? 0
                } else if let combined = self.combined {
                    level = combined.audioLevel
                } else if let recorder = self.recorder {
                    recorder.updateMeters()
                    level = pow(10, recorder.averagePower(forChannel: 0) / 20)
                } else {
                    level = 0
                }
                ball.updateAudioLevel(level)
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        indicatorMeter = timer
    }

    private func makeIndicator(near frame: NSRect?) -> NSPanel? {
        let reference = frame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(reference) }) ?? NSScreen.main else { return nil }
        let area = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = ActivityBall.recordingSize
        let initial = NSPoint(x: area.maxX - 2 * size - 6, y: area.maxY - size)
        let origin = position.flatMap { point in
            NSScreen.screens.contains { $0.visibleFrame.contains(NSRect(origin: point, size: NSSize(width: size, height: size))) }
                ? point : nil
        } ?? initial
        let dot = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dot.level = .floating
        dot.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dot.isOpaque = false
        dot.backgroundColor = .clear
        dot.hidesOnDeactivate = false
        dot.isReleasedWhenClosed = false
        dot.hasShadow = false
        let content = RecordingIndicatorContent(size: size)
        content.ball.moved = { [weak self, weak content] _ in self?.position = content?.dotFrame?.origin }
        dot.contentView = content
        return dot
    }

    static func openAudioPrivacySettings() {
        guard let address = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(address)
    }

    private func confirmSystemAudio() -> Bool {
        let alert = NSAlert()
        alert.messageText = AppText.t("Record your microphone and Mac audio?")
        alert.informativeText = AppText.t("Allow system audio when macOS asks. For video notes, play the video after recording starts. Headphones keep playback out of the microphone. You can change the sources in FloatChat’s Recording settings.")
        alert.addButton(withTitle: AppText.t("Continue"))
        alert.addButton(withTitle: AppText.t("Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMessage(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = AppText.t(message)
        alert.informativeText = AppText.t(detail)
        NSApp.activate()
        alert.runModal()
    }
}

/// Opens the recording folder inside the user's normal file chooser.
@MainActor
final class RecordingPickerShortcut: NSButton {
    private weak var picker: NSOpenPanel?
    private let directory: URL

    init(picker: NSOpenPanel, directory: URL = MeetingRecorder.folder) {
        self.picker = picker
        self.directory = directory
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 28))
        title = AppText.t("Recordings…")
        bezelStyle = .rounded
        target = self
        action = #selector(openRecordings)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openRecordings() { picker?.directoryURL = directory }
}
