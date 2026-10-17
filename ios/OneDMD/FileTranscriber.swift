import AVFoundation
import Speech

/// Turns an audio file into text, on the phone, with Apple's SpeechAnalyzer (iOS 26+).
/// Free and offline: the audio never leaves the device, only the text does.
enum FileTranscriber {
    static func transcribe(_ file: URL) async throws -> String {
        guard await requestPermission() else { throw FileTranscriberError.notAllowed }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw FileTranscriberError.unsupportedLanguage
        }

        // No draft results: only finished phrases matter for a file.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])

        // The speech model may need a one-time download.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: file)
        } catch {
            throw FileTranscriberError.unreadable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = transcriber.results
        let collecting = Task {
            var phrases: [String] = []
            for try await result in results where result.isFinal {
                let phrase = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { phrases.append(phrase) }
            }
            return phrases.joined(separator: " ")
        }

        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                collecting.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collecting.cancel()
            throw error
        }

        let text = try await collecting.value
        try Task.checkCancellation()
        guard !text.isEmpty else { throw FileTranscriberError.noSpeech }
        return text
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
