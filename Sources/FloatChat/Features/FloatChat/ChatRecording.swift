import AppKit
import WebKit

@MainActor
final class ChatRecording {
    let key: String
    weak var view: WKWebView?
    let url: URL
    var file: URL?
    var savedAt: Date?
    var pendingAttachment = false
    var didHandOff = false
    var attachmentConfirmed = false
    var attemptedInBackground = false
    var downloadCopyFailed = false
    var attachmentFailed = false

    init(key: String, view: WKWebView, url: URL) {
        self.key = key
        self.view = view
        self.url = url
    }

    func matches(_ candidate: WKWebView?, key: String) -> Bool {
        guard let candidate else { return false }
        return candidate === view && candidate.url == url && self.key == key
    }

    static let openAudioPicker = #"""
        if (location.href !== new URL(address).href) return false;
        const eligible = node => {
            if (node.disabled || node.webkitdirectory) return false;
            const formats = node.accept.toLowerCase().split(',').map(item => item.trim());
            return formats.some(item => ['', '*/*', 'audio/*', '.m4a', 'audio/mp4', 'audio/x-m4a'].includes(item));
        };
        const inputs = [...document.querySelectorAll('input[type="file"]')].filter(eligible);
        const editor = document.querySelector('#prompt-textarea');
        const inComposer = inputs.filter(input => editor?.closest('form')?.contains(input));
        const input = inComposer.length === 1 ? inComposer[0] : inputs.length === 1 ? inputs[0] : null;
        if (!input) return false;
        return await new Promise(resolve => {
            const finish = value => {
                input.removeEventListener('change', changed, true);
                clearTimeout(timeout);
                resolve(value);
            };
            const changed = () => finish(Array.from(input.files || []).some(file => file.name === filename && file.size > 0));
            const timeout = setTimeout(() => finish(false), 3000);
            input.addEventListener('change', changed, true);
            input.click();
        });
        """#

    static let addPrompt = #"""
        if (location.href !== new URL(address).href) return false;
        const editor = document.querySelector('#prompt-textarea:is([contenteditable="true"], textarea)');
        if (!editor || (editor.value ?? editor.innerText).trim()) return false;
        if (document.activeElement !== editor) editor.focus({preventScroll: true});
        return document.execCommand('insertText', false, prompt);
        """#
}

extension FloatChatController {
    func isRecordingPage(_ view: WKWebView?) -> Bool {
        guard let view else { return false }
        return meetingRecorder.isRecording && recordingChat?.view === view
    }

    func supportsRecordingAttachment(to url: URL) -> Bool {
        Self.isHTTPSPage(url) && (url.host == "chatgpt.com" || url.host == "www.chatgpt.com")
            && (url.port ?? 443) == 443
    }

    private func recordingPage(for recording: ChatRecording) -> WKWebView? {
        if recording.matches(webView, key: providers[selectedIndex].key) { return webView }
        let parked = parkedPages[recording.key]?.view
        return recording.matches(parked, key: recording.key) ? parked : nil
    }

    func canAttachRecording(_ recording: ChatRecording) -> Bool {
        !recording.didHandOff && supportsRecordingAttachment(to: recording.url)
            && recordingPage(for: recording) != nil
            && (recording.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    func recordingDidSave(_ file: URL, automaticallyAttach: Bool) {
        guard let recording = recordingChat else { return }
        latestRecordingFile = file
        recording.file = file
        recording.savedAt = .now
        recording.pendingAttachment = automaticallyAttach && supportsRecordingAttachment(to: recording.url)
        if !recording.pendingAttachment {
            showRecordingNotice("Recording saved. Use Save Last Recording from the FloatChat menu.")
        }
        if preferences.bool(forKey: "keepRecordingCopyInDownloads") {
            do {
                _ = try Self.copyRecording(file, to: .downloadsDirectory, reserved: Set(downloads.values.map(\.destination)))
            } catch {
                recording.downloadCopyFailed = true
            }
        }
        prunePages()
        updateStatus()
        attachPendingRecording()
    }

    @discardableResult
    static func copyRecording(_ file: URL, to directory: URL, reserved: Set<URL> = []) throws -> URL {
        let destination = uniqueDownloadURL(suggestedFilename: file.lastPathComponent, reserved: reserved, in: directory)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    func attachPendingRecording() {
        guard let recording = recordingChat, recording.pendingAttachment, canAttachRecording(recording),
              recordingUpload == nil, let page = recordingPage(for: recording), let file = recording.file,
              !page.isLoading else { return }
        let inBackground = page !== webView || panel?.isVisible != true
        guard !inBackground || !recording.attemptedInBackground else { return }
        recording.attemptedInBackground = inBackground
        let token = UUID()
        recordingUpload = token
        updateStatus()
        page.callAsyncJavaScript(ChatRecording.openAudioPicker, arguments: [
            "address": recording.url.absoluteString, "filename": file.lastPathComponent
        ], in: nil, in: .defaultClient) { [weak self, weak page] result in
            guard let self, self.recordingUpload == token else { return }
            if let page, recording.didHandOff, self.recordingPage(for: recording) === page,
               case .success(let value) = result, value as? Bool == true {
                self.recordingUpload = nil
                recording.attachmentConfirmed = true
                recording.pendingAttachment = false
                recording.savedAt = .now
                self.prunePages()
                self.stageRecordingPrompt(in: page)
                let notice = self.meetingRecorder.lastHadSystemAudio == false
                    ? "Audio added to the draft. No system audio was detected."
                    : "Audio added to the draft. Review it and send."
                self.showRecordingNotice(notice, for: recording.key)
            } else {
                self.finishRecordingAttempt(token)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishRecordingAttempt(token) }
    }

    private func finishRecordingAttempt(_ token: UUID) {
        guard recordingUpload == token, let recording = recordingChat else { return }
        recordingUpload = nil
        if recording.didHandOff || !recording.attemptedInBackground || recordingPage(for: recording) == nil {
            recording.pendingAttachment = false
            recording.attachmentFailed = true
        }
        updateStatus()
        if recording.attemptedInBackground, webView === recording.view, panel?.isVisible == true {
            attachPendingRecording()
        }
    }

    func invalidateRecordingPage(_ page: WKWebView) {
        guard let recording = recordingChat, recording.view === page else { return }
        recording.view = nil
        recordingUpload = nil
        recording.pendingAttachment = false
        recording.attachmentFailed = true
        updateStatus()
    }

    func takeRecordingAttachment(in page: WKWebView, frame: WKFrameInfo) -> URL? {
        guard recordingUpload != nil, let recording = recordingChat, canAttachRecording(recording),
              recordingPage(for: recording) === page, frame.isMainFrame, frame.securityOrigin.protocol == "https",
              frame.securityOrigin.host == recording.url.host,
              [0, 443].contains(frame.securityOrigin.port), let file = recording.file else { return nil }
        recording.didHandOff = true
        updateStatus()
        return file
    }

    var lastRecordingFile: URL? {
        if let file = latestRecordingFile, FileManager.default.fileExists(atPath: file.path) { return file }
        return MeetingRecorder.latestStagedRecording()
    }

    func saveLastRecording() {
        guard let file = lastRecordingFile else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = file.lastPathComponent
        save.directoryURL = .downloadsDirectory
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = save.url else { return }
            do {
                let options: Data.WritingOptions = .atomic
                try Data(contentsOf: file, options: .mappedIfSafe).write(to: destination, options: options)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let panel, panel.isVisible { save.beginSheetModal(for: panel, completionHandler: finish) }
        else { NSApp.activate(); save.begin(completionHandler: finish) }
    }

    func stageRecordingPrompt(in page: WKWebView) {
        guard let recording = recordingChat, recordingPage(for: recording) === page else { return }
        page.callAsyncJavaScript(ChatRecording.addPrompt, arguments: [
            "address": recording.url.absoluteString, "prompt": AppText.t("Please transcribe this audio recording.")
        ], in: nil, in: .defaultClient, completionHandler: nil)
    }
}
