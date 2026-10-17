import AVFoundation
import Observation
import Speech

/// Turns the mic into text, on the phone, with Apple's SpeechAnalyzer (iOS 26+).
///
/// It doesn't open the mic itself: AudioLevelMonitor already taps it for the waveform,
/// and hands each buffer to `feed`. Two paths come out:
/// - `draftText`: the words being heard right now, rewritten as recognition firms up (fast path).
/// - `finalText`: finished phrases, appended once and never changed (what the AI will read).
@MainActor
@Observable
final class AudioTranscriber {
    enum Status: Equatable {
        case idle, preparing, listening
        case unavailable(String)
    }

    private(set) var finalText = ""
    private(set) var draftText = ""
    private(set) var status: Status = .idle

    /// Receives mic buffers on the audio thread. Safe to call from any thread.
    let feed = TranscriberFeed()

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    func start() async {
        guard status != .preparing, status != .listening else { return }
        finalText = ""
        draftText = ""
        status = .preparing

        guard await Self.requestPermission() else {
            status = .unavailable("Speech recognition is off. Turn it on in Settings.")
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            status = .unavailable("This language isn't supported for transcription yet.")
            return
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        do {
            // The speech model may need a one-time download.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                status = .unavailable("Couldn't set up the audio for transcription.")
                return
            }
            let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {
                    self?.status = .unavailable("Transcription stopped: \(error.localizedDescription)")
                }
            }

            try await analyzer.start(inputSequence: input)
            self.analyzer = analyzer
            feed.begin(format: format, continuation: continuation)
            status = .listening
        } catch {
            status = .unavailable("Couldn't start transcription: \(error.localizedDescription)")
        }
    }

    /// Pause keeps the session; words resume where they left off.
    func setPaused(_ paused: Bool) {
        feed.setPaused(paused)
    }

    func stop() async {
        feed.end()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        draftText = ""
        status = .idle
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            finalText += finalText.isEmpty ? trimmed : " " + trimmed
            draftText = ""
        } else {
            draftText = text
        }
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// Converts mic buffers to the format the analyzer wants and passes them on.
/// Called from the audio thread, so everything here is behind a lock.
final class TranscriberFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var paused = false

    func begin(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        self.format = format
        self.continuation = continuation
        converter = nil
        paused = false
    }

    func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.paused = paused
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
        format = nil
        converter = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !paused, let continuation, let format else { return }

        if buffer.format == format {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var handedOver = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }
}
