import AVFoundation
import Speech

/// Turns an audio file into text on the phone using Apple's SpeechAnalyzer (iOS 26+).
/// The speech model may need a one-time download; only text is sent to the backend.
enum FileTranscriber {
    /// Transcribes a picked file locally; only the resulting text is sent to the backend.
    static func transcribe(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        guard await requestPermission() else {
            throw FileTranscriberError.notAllowed
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw FileTranscriberError.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FileTranscriberError.unreadable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            var phrases: [String] = []
            for try await result in transcriber.results where result.isFinal {
                try Task.checkCancellation()
                phrases.append(String(result.text.characters))
            }
            return phrases.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        defer { results.cancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let transcript = try await results.value
                try Task.checkCancellation()
                guard !transcript.isEmpty else {
                    throw FileTranscriberError.noSpeech
                }
                return transcript
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
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

enum FileTranscriberError: LocalizedError {
    case notAllowed, unsupportedLanguage, unreadable, noSpeech

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Speech recognition is off. Turn it on in Settings."
        case .unsupportedLanguage: "This language isn't supported for transcription yet."
        case .unreadable: "This audio file couldn't be opened."
        case .noSpeech: "No speech was found in this recording."
        }
    }
}
