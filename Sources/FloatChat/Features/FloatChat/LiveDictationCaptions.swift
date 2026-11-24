import AVFoundation
import Speech

@MainActor
protocol DictationCaptionInput: AnyObject {
    func append(_ pcm: Data)
    func stop()
}

/// Receives the same mono PCM already being sent to the website. Uses macOS's
/// local speech model and keeps only a short in-memory buffer during startup.
@available(macOS 26, *)
@MainActor
final class LiveDictationCaptions: DictationCaptionInput {
    private let sourceFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var work: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var pending = Data()

    init?(sampleRate: Double, locale: Locale, onText: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
        guard SpeechTranscriber.isAvailable,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        sourceFormat = format
        work = Task { [weak self] in
            do {
                guard let language = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    if !Task.isCancelled { onUnavailable() }
                    return
                }
                let transcriber = SpeechTranscriber(locale: language, preset: .progressiveTranscription)
                if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await download.downloadAndInstall()
                }
                try Task.checkCancellation()
                guard let self,
                      let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                                 considering: format),
                      let converter = AVAudioConverter(from: format, to: target) else {
                    if !Task.isCancelled { onUnavailable() }
                    return
                }
                try Task.checkCancellation()
                let analyzer = SpeechAnalyzer(modules: [transcriber],
                                              options: .init(priority: .utility, modelRetention: .whileInUse))
                self.analyzer = analyzer
                try await analyzer.prepareToAnalyze(in: target)
                try Task.checkCancellation()
                let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(24))
                self.converter = converter
                self.input = input
                self.append(self.pending)
                self.pending = Data()
                self.results = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard !Task.isCancelled else { return }
                            let tail = String(result.text.characters.suffix(112))
                            if !tail.isEmpty { onText(tail) }
                        }
                    } catch {
                        if !Task.isCancelled { self?.stop(); onUnavailable() }
                    }
                }
                try await analyzer.start(inputSequence: stream)
            } catch {
                if !Task.isCancelled { self?.stop(); onUnavailable() }
            }
        }
    }

    func append(_ pcm: Data) {
        guard !pcm.isEmpty, work != nil else { return }
        guard let converter, let input else {
            pending.append(pcm)
            let limit = Int(sourceFormat.sampleRate) * MemoryLayout<Float>.size * 3
            if pending.count > limit { pending.removeFirst(pending.count - limit) }
            return
        }
        let frames = pcm.count / MemoryLayout<Float>.size
        guard frames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let destination = source.floatChannelData?[0] else { return }
        source.frameLength = AVAudioFrameCount(frames)
        _ = pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: pcm.count))
        let capacity = ceil(Double(frames) * converter.outputFormat.sampleRate / sourceFormat.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else { return }
        var supplied = false
        let status = converter.convert(to: output, error: nil) { _, state in
            state.pointee = supplied ? .noDataNow : .haveData
            if supplied { return nil }
            supplied = true
            return source
        }
        if status != .error, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
    }

    func stop() {
        work?.cancel()
        work = nil
        results?.cancel()
        results = nil
        input?.finish()
        input = nil
        pending = Data()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }
}
