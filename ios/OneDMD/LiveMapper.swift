import Foundation
import Observation

/// Builds the map while people talk. Feed it the transcriber's finished text; it sends new
/// words to the live endpoint once ~20 have piled up or after a pause, one request at a
/// time, and keeps the latest map. A network failure (or the server saying it's busy for
/// now: 429/502/503/504) keeps the map and the words, and is retried after the next pause
/// rather than straight away. Any other failure (a 422 for a Claude refusal or unusable
/// reply, a 400) skips that batch: its words stay in the transcript but aren't sent again,
/// so one bad batch can't freeze the map. One request carries at most `maxChunkChars` of
/// new words (oldest first, cut at a word boundary), so a long offline backlog stays under
/// the server's size cap; the rest goes out in the next request(s) straight away.
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
    private let maxChunkChars: Int
    /// Everything heard so far (the transcriber's finalText) and how much of it was sent.
    private var heardText = ""
    private var sentCount = 0
    private var previousWords = ""
    private var inFlight: Task<Void, Never>?
    private var pauseTimer: Task<Void, Never>?
    /// Set by finish(): from then on only finish() sends, so leftovers can't go out twice.
    private var finishing = false
    /// True after a request that left words behind (a long backlog): send the rest at once.
    private var sendRestNow = false

    init(backend: any LiveBackend, startingMap: NodeMapData?, wordsPerUpdate: Int = 20,
         pause: Duration = .seconds(3), finishDeadline: Duration = .seconds(5),
         maxChunkChars: Int = 15_000) {
        self.maxChunkChars = maxChunkChars
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
        // Both racers are pinned to the main actor and share one ResumeOnce, so whichever
        // finishes second can never resume the continuation again.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let deadline = Task { @MainActor [finishDeadline] in
                try? await Task.sleep(for: finishDeadline)
                once.resume()
            }
            Task { @MainActor [weak self] in
                while let task = self?.inFlight { await task.value }
                // A long backlog goes in several requests; stop as soon as one doesn't get through.
                while let self, !self.pending.isEmpty {
                    let before = self.sentCount
                    await self.send()
                    if self.sentCount == before { break }
                }
                deadline.cancel()   // done in time: don't leave the timer running
                once.resume()
            }
        }
        return map
    }

    private func decide() {
        guard !finishing, inFlight == nil, !pending.isEmpty else { return }
        if !isOffline, sendRestNow || Self.wordCount(pending) >= wordsPerUpdate {
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
            guard !Task.isCancelled, let self else { return }
            // This timer has fired, so drop its handle even if there's nothing to send:
            // a stale handle would stop decide() from arming a retry while offline.
            self.pauseTimer = nil
            guard !self.finishing, self.inFlight == nil, !self.pending.isEmpty else { return }
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

    /// The next request's words (at most `maxChunkChars`, cut at a word boundary) and how far
    /// into `heardText` they reach.
    private func nextChunk() -> (words: String, upTo: Int) {
        let rest = heardText.dropFirst(sentCount)
        let skipped = rest.prefix(while: \.isWhitespace).count
        let body = rest.dropFirst(skipped)
        guard body.count > maxChunkChars else {
            return (body.trimmingCharacters(in: .whitespacesAndNewlines), heardText.count)
        }
        let head = body.prefix(maxChunkChars)
        var cut = maxChunkChars
        let next = body[body.index(body.startIndex, offsetBy: maxChunkChars)]
        if !next.isWhitespace, let space = head.lastIndex(where: \.isWhitespace) {
            cut = body.distance(from: body.startIndex, to: space)
        }
        let words = body.prefix(cut).trimmingCharacters(in: .whitespacesAndNewlines)
        return (words, sentCount + skipped + cut)
    }

    private func send() async {
        sendRestNow = false
        let (words, upTo) = nextChunk()
        let request = LiveRequest(outline: map?.liveOutline, previousWords: previousWords, words: words)
        do {
            let reply = try await backend.update(request)
            if let newMap = reply.map { map = newMap }
            previousWords = words
            sentCount = upTo
            isOffline = false
            sendRestNow = !pending.isEmpty && upTo < heardText.count
        } catch where error is URLError || MapService.isTemporary(error) {
            // Network trouble, or the server busy for now (429/502/503/504): keep the map and
            // the words; decide() waits for the pause timer to retry.
            isOffline = true
        } catch {
            // The server answered but couldn't use these words (refusal, bad request, garbled
            // reply). Sending them again would fail the same way, so move past them.
            sentCount = upTo
            isOffline = false
        }
    }
}

/// Resumes a continuation the first time resume() is called and ignores later calls.
/// Main-actor isolated, so the check and the resume can't interleave across threads.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
