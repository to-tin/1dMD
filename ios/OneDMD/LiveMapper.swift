import Foundation
import Observation

/// Builds the map while people talk. Feed it the transcriber's finished text; it sends new
/// words to the live endpoint once ~20 have piled up or after a pause, one request at a
/// time, and keeps the latest map. A failed request keeps the map and the words, and is
/// retried after the next pause rather than straight away.
///
/// Use one LiveMapper per recording: it assumes the transcriber's finished text only grows
/// during that recording (a shorter text is taken to mean the transcriber restarted).
@MainActor
@Observable
final class LiveMapper {
    private(set) var map: NodeMapData?
    private(set) var isOffline = false

    private let backend: any LiveBackend
    private let wordsPerUpdate: Int
    private let pause: Duration
    private let finishDeadline: Duration
    /// Everything heard so far (the transcriber's finalText) and how much of it was sent.
    private var heardText = ""
    private var sentCount = 0
    private var previousWords = ""
    private var inFlight: Task<Void, Never>?
    private var pauseTimer: Task<Void, Never>?
    /// Set by finish(): from then on only finish() sends, so leftovers can't go out twice.
    private var finishing = false

    init(backend: any LiveBackend, startingMap: NodeMapData?, wordsPerUpdate: Int = 20,
         pause: Duration = .seconds(3), finishDeadline: Duration = .seconds(5)) {
        self.finishDeadline = finishDeadline
        self.backend = backend
        self.map = startingMap.flatMap { $0.nodes.isEmpty ? nil : $0 }
        self.wordsPerUpdate = wordsPerUpdate
        self.pause = pause
    }

    private var pending: String {
        String(heardText.dropFirst(sentCount)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Call whenever the transcriber's finished text changes.
    func heard(_ finalText: String) {
        heardText = finalText
        if sentCount > heardText.count { sentCount = 0 }   // transcriber restarted
        decide()
    }

    /// Send the leftover words once (after any request in flight), then return the map.
    func finish() async -> NodeMapData? {
        finishing = true
        pauseTimer?.cancel()
        // Wait for the request in flight and send the leftovers, but never longer than the
        // deadline. A hung server must not hang Stop; the words stay in the transcript.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resumeOnce = { if !resumed { resumed = true; continuation.resume() } }
            Task { [weak self] in
                while let task = self?.inFlight { await task.value }
                if let self, !self.pending.isEmpty { await self.send() }
                resumeOnce()
            }
            Task { [finishDeadline] in
                try? await Task.sleep(for: finishDeadline)
                resumeOnce()
            }
        }
        return map
    }

    private func decide() {
        guard !finishing, inFlight == nil, !pending.isEmpty else { return }
        if !isOffline, Self.wordCount(pending) >= wordsPerUpdate {
            startSending()
        } else if isOffline, pauseTimer != nil {
            // Retry fires one pause after the failure; more speech must not keep pushing it back.
        } else {
            restartPauseTimer()
        }
    }

    private func restartPauseTimer() {
        pauseTimer?.cancel()
        pauseTimer = Task { [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self, !self.finishing, self.inFlight == nil, !self.pending.isEmpty else { return }
            self.pauseTimer = nil
            self.startSending()
        }
    }

    private func startSending() {
        pauseTimer?.cancel()
        pauseTimer = nil
        inFlight = Task { [weak self] in
            await self?.send()
            self?.inFlight = nil
            self?.decide()
        }
    }

    private func send() async {
        let words = pending
        let upTo = heardText.count
        let request = LiveRequest(outline: map?.liveOutline, previousWords: previousWords, words: words)
        do {
            let reply = try await backend.update(request)
            if let newMap = reply.map { map = newMap }
            previousWords = words
            sentCount = upTo
            isOffline = false
        } catch {
            isOffline = true   // keep map and words; decide() waits for the pause timer
        }
    }
}
