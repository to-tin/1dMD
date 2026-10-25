import XCTest
@testable import OneDMD

/// Scripted stand-in for the server. Each call answers with the next result; it records
/// requests and can hold a reply until released.
actor FakeLive: LiveBackend {
    var requests: [LiveRequest] = []
    var results: [Result<LiveReply, Error>] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdNext = false

    func script(_ results: [Result<LiveReply, Error>]) { self.results = results }
    func hold() { holdNext = true }
    var released = false
    func release() {
        if let gate { gate.resume(); self.gate = nil } else { released = true }
    }

    func update(_ request: LiveRequest) async throws -> LiveReply {
        requests.append(request)
        if holdNext {
            holdNext = false
            if released { released = false } else {
                await withCheckedContinuation { gate = $0 }
            }
        }
        let next = results.isEmpty ? .success(LiveReply(map: request.outline.map { _ in .sample }, move: "stay")) : results.removeFirst()
        return try next.get()
    }
}

@MainActor
final class LiveMapperTests: XCTestCase {
    private func reply(_ current: String) -> LiveReply {
        var map = NodeMapData.sample
        map.currentID = current
        map.outline = MapOutline(nodes: [.init(id: current, title: current, parent: "", continues: "", description: "", bullets: [])], current: current)
        return LiveReply(map: map, move: "stay")
    }

    private func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }

    func testSendsOnceEnoughWordsArrive() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 5, pause: .seconds(10))
        mapper.heard("one two three")
        await settle()
        var count = await fake.requests.count
        XCTAssertEqual(count, 0)
        mapper.heard("one two three four five")
        await settle()
        count = await fake.requests.count
        XCTAssertEqual(count, 1)
        let first = await fake.requests[0]
        XCTAssertEqual(first.words, "one two three four five")
        XCTAssertNil(first.outline)
        XCTAssertEqual(mapper.map?.currentID, "a")
    }

    func testPauseSendsFewerWords() async {
        let fake = FakeLive()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 20, pause: .milliseconds(100))
        mapper.heard("just three words")
        await settle()
        let count = await fake.requests.count
        XCTAssertEqual(count, 1)
    }

    func testWordsDuringRequestRideAlongNext() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .success(reply("b"))])
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(100))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four")          // arrives while the first is held
        mapper.heard("one two three four five six")
        await settle(0.1)
        var count = await fake.requests.count
        XCTAssertEqual(count, 1)                     // still one at a time
        await fake.release()
        await settle()
        count = await fake.requests.count
        XCTAssertEqual(count, 2)
        let second = await fake.requests[1]
        XCTAssertEqual(second.words, "three four five six")   // nothing dropped, nothing repeated
        XCTAssertEqual(second.previousWords, "one two")
        XCTAssertEqual(second.outline?.current, "a")
        XCTAssertEqual(mapper.map?.currentID, "b")
    }

    func testOfflineKeepsMapAndRetriesOnPause() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .failure(URLError(.notConnectedToInternet)), .success(reply("b"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(150))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four")
        await settle(0.05)
        XCTAssertTrue(mapper.isOffline)
        XCTAssertEqual(mapper.offlineReason, "The phone isn't on a network. Turn on Wi-Fi.")
        XCTAssertEqual(mapper.map?.currentID, "a")           // map unchanged
        var count = await fake.requests.count
        XCTAssertEqual(count, 2)                              // no instant retry loop
        await settle(0.3)
        count = await fake.requests.count
        XCTAssertEqual(count, 3)
        let retry = await fake.requests[2]
        XCTAssertEqual(retry.words, "three four")             // words kept
        XCTAssertFalse(mapper.isOffline)
        XCTAssertNil(mapper.offlineReason)
        XCTAssertEqual(mapper.map?.currentID, "b")
    }

    func testRejectedBatchIsSkippedNotRetried() async {
        for status in [400, 422] {
            let fake = FakeLive()
            await fake.script([.success(reply("a")), .failure(MapServiceError.server(status, "refused")), .success(reply("b"))])
            let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(150))
            mapper.heard("one two")
            await settle(0.1)
            mapper.heard("one two three four")
            await settle(0.1)
            XCTAssertFalse(mapper.isOffline, "\(status)")
            XCTAssertEqual(mapper.map?.currentID, "a", "\(status)")        // map unchanged
            await settle(0.3)                                                // past a pause: no retry
            var count = await fake.requests.count
            XCTAssertEqual(count, 2, "\(status)")
            mapper.heard("one two three four five six")
            await settle(0.1)
            count = await fake.requests.count
            XCTAssertEqual(count, 3, "\(status)")
            let words = await fake.requests.map(\.words)
            XCTAssertEqual(words.last, "five six", "\(status)")             // only newer words
            XCTAssertEqual(mapper.map?.currentID, "b", "\(status)")
        }
    }

    func testLongBacklogGoesInOrderedChunksNothingLostOrRepeated() async {
        let fake = FakeLive()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2,
                                pause: .seconds(10), maxChunkChars: 20)
        // 8 words of 4 chars + spaces = 39 chars: needs 2+ requests at 20 chars each.
        let text = "aaaa bbbb cccc dddd eeee ffff gggg hhhh"
        mapper.heard(text)
        await settle(0.5)                                   // no pause wait for the rest
        let words = await fake.requests.map(\.words)
        XCTAssertGreaterThanOrEqual(words.count, 2)
        XCTAssertTrue(words.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(words.joined(separator: " "), text)  // in order, none lost or doubled
    }

    func testWordsHeardDuringARequestWaitForTheNormalTrigger() async {
        let fake = FakeLive()
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 20, pause: .seconds(10))
        let first = (1...20).map { "w\($0)" }.joined(separator: " ")
        mapper.heard(first)
        await settle()
        mapper.heard(first + " x y z")
        await fake.release()
        await settle(0.5)
        let count = await fake.requests.count
        XCTAssertEqual(count, 1)
    }

    func testBusyServerIsRetriedLikeOffline() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .failure(MapServiceError.server(503, "busy")), .success(reply("b"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(150))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four")
        await settle(0.05)
        XCTAssertTrue(mapper.isOffline)
        XCTAssertEqual(mapper.map?.currentID, "a")
        await settle(0.3)
        let words = await fake.requests.map(\.words)
        XCTAssertEqual(words, ["one two", "three four", "three four"])   // same words retried
        XCTAssertFalse(mapper.isOffline)
        XCTAssertEqual(mapper.map?.currentID, "b")
    }

    func testOfflineThenRejectedSkipsTheBatchAndClearsOffline() async {
        let fake = FakeLive()
        await fake.script([.failure(URLError(.notConnectedToInternet)), .failure(MapServiceError.server(422, "bad")),
                           .success(reply("c"))])
        let mapper = LiveMapper(backend: fake, startingMap: .sample, wordsPerUpdate: 2, pause: .milliseconds(150))
        mapper.heard("one two")
        await settle(0.05)
        XCTAssertTrue(mapper.isOffline)
        await settle(0.3)                       // the retry goes out and is rejected
        var words = await fake.requests.map(\.words)
        XCTAssertEqual(words, ["one two", "one two"])
        XCTAssertFalse(mapper.isOffline)
        XCTAssertEqual(mapper.map?.currentID, "pizza")
        await settle(0.3)                       // skipped: not sent a third time
        words = await fake.requests.map(\.words)
        XCTAssertEqual(words.count, 2)
        mapper.heard("one two three four")
        await settle(0.1)
        words = await fake.requests.map(\.words)
        XCTAssertEqual(words.last, "three four")
        XCTAssertEqual(mapper.map?.currentID, "c")
    }

    func testOfflineTimerFiringWithNothingPendingDoesNotBlockRetries() async {
        let fake = FakeLive()
        await fake.script([.failure(URLError(.notConnectedToInternet)), .success(reply("b"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(150))
        mapper.heard("one two")
        await settle(0.05)
        XCTAssertTrue(mapper.isOffline)
        mapper.heard("")              // transcriber restarted: nothing pending when the timer fires
        await settle(0.3)
        mapper.heard("three four")
        await settle(0.4)
        let requests = await fake.requests
        XCTAssertEqual(requests.map(\.words), ["one two", "three four"])
        XCTAssertFalse(mapper.isOffline)
        XCTAssertEqual(mapper.map?.currentID, "b")
    }

    func testFinishWaitsAndSendsLeftovers() async {
        let fake = FakeLive()
        await fake.script([.success(reply("a")), .success(reply("b"))])
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .seconds(10))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three")
        Task { try? await Task.sleep(for: .milliseconds(100)); await fake.release() }
        let final = await mapper.finish()
        XCTAssertEqual(final?.currentID, "b")
        let last = await fake.requests.last
        XCTAssertEqual(last?.words, "three")
    }

    func testFinishNeverSendsLeftoversTwice() async {
        let fake = FakeLive()
        await fake.hold()
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .seconds(10))
        mapper.heard("one two")
        await settle(0.1)
        mapper.heard("one two three four five")   // enough for its own batch once the first lands
        Task { try? await Task.sleep(for: .milliseconds(100)); await fake.release() }
        _ = await mapper.finish()
        await settle()
        let words = await fake.requests.map(\.words)
        XCTAssertEqual(words, ["one two", "three four five"])
    }

    func testContinuingStartsFromTheSavedOutline() async {
        let fake = FakeLive()
        let mapper = LiveMapper(backend: fake, startingMap: .sample, wordsPerUpdate: 1, pause: .seconds(10))
        XCTAssertEqual(mapper.map?.currentID, "pizza")
        mapper.heard("hello")
        await settle()
        let first = await fake.requests.first
        XCTAssertEqual(first?.outline?.current, "pizza")
    }

    func testNoMapFromServerKeepsCurrentMap() async {
        let fake = FakeLive()
        await fake.script([.success(LiveReply(map: nil, move: "none"))])
        let mapper = LiveMapper(backend: fake, startingMap: .sample, wordsPerUpdate: 1, pause: .seconds(10))
        mapper.heard("hello")
        await settle()
        XCTAssertEqual(mapper.map?.currentID, "pizza")
    }

    func testFinishGivesUpAtTheDeadline() async {
        let fake = FakeLive()
        await fake.hold()   // never released
        let mapper = LiveMapper(backend: fake, startingMap: .sample, wordsPerUpdate: 1, pause: .seconds(10), finishDeadline: .milliseconds(300))
        mapper.heard("hello")
        await settle(0.1)
        let start = Date()
        let final = await mapper.finish()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(final?.currentID, "pizza")
    }

    func testOfflineRetryIsNotStarvedByContinuousSpeech() async {
        let fake = FakeLive()
        await fake.script([.failure(URLError(.notConnectedToInternet)), .success(reply("b"))])
        let mapper = LiveMapper(backend: fake, startingMap: nil, wordsPerUpdate: 2, pause: .milliseconds(200))
        var text = "one two"
        mapper.heard(text)
        await settle(0.05)
        XCTAssertTrue(mapper.isOffline)
        // Keep talking, phrases closer together than the pause, for longer than the pause.
        var words = 2
        for _ in 0..<10 {
            words += 1
            text += " w\(words)"
            mapper.heard(text)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let requests = await fake.requests
        XCTAssertGreaterThanOrEqual(requests.count, 2)         // retry fired during speech
        guard requests.count >= 2 else { return }
        XCTAssertTrue(requests[1].words.hasPrefix("one two"))  // everything unsent is included
        XCTAssertTrue(requests[1].words.hasSuffix("w5") || requests[1].words.split(separator: " ").count >= 5)
        XCTAssertFalse(mapper.isOffline)
    }
}

final class PlaceholderLiveTests: XCTestCase {
    func testGrowsThenStopsAtFullSample() async throws {
        let backend = PlaceholderBackend()
        var outline: MapOutline?
        var counts: [Int] = []
        for _ in 0..<(NodeMapData.sample.edges.count + 3) {
            let reply = try await backend.update(LiveRequest(outline: outline, previousWords: "", words: "x"))
            let map = try XCTUnwrap(reply.map)
            let next = try XCTUnwrap(map.outline)
            XCTAssertTrue(next.nodes.contains { $0.id == next.current }, "current node must exist")
            counts.append(map.nodes.count)
            outline = next
        }
        XCTAssertEqual(counts.first, 1)
        XCTAssertEqual(counts, counts.sorted())
        XCTAssertGreaterThan(counts[1], counts[0])
        XCTAssertEqual(counts.last, NodeMapData.sample.nodes.count)
        let reply = try await backend.update(LiveRequest(outline: outline, previousWords: "", words: "x"))
        XCTAssertEqual(reply.move, "none")
        XCTAssertEqual(reply.map?.nodes.count, NodeMapData.sample.nodes.count)
    }

    func testFlagRoutesLiveBackendToPlaceholder() {
        let key = "usePlaceholderBackend"
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(MapService.liveBackend is PlaceholderBackend)
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(MapService.liveBackend is PlaceholderBackend)
    }
}

/// The plain-language connection messages and the drawer's Test check.
final class ServerCheckTests: XCTestCase {
    private let lan = URL(string: "http://192.168.1.20:8000")!

    func testExplainsEachCommonFailure() {
        XCTAssertEqual(MapService.explain(URLError(.cannotConnectToHost), server: lan),
                       "Nothing is answering at 192.168.1.20:8000. On the Mac, run ./1dmd start --host 0.0.0.0.")
        XCTAssertTrue(MapService.explain(URLError(.timedOut), server: lan).contains("same Wi-Fi"))
        XCTAssertTrue(MapService.explain(MapServiceError.server(502, ""), server: lan).contains("(502)"))
        // The simulator really does reach the Mac at 127.0.0.1, so no "this is your phone" warning.
        XCTAssertTrue(MapService.explain(URLError(.cannotConnectToHost), server: MapService.defaultServerURL)
            .hasPrefix("Nothing is answering at 127.0.0.1:8000"))
    }

    func testCheckReportsHealthyBrokenAndUnreachableServers() async {
        let session = StubProtocol.session()
        StubProtocol.answer = .status(200)
        let healthy = await MapService.check(lan, session: session)
        XCTAssertNil(healthy)
        XCTAssertEqual(StubProtocol.lastURL?.absoluteString, "http://192.168.1.20:8000/health")

        StubProtocol.answer = .status(404)
        let wrongServer = await MapService.check(lan, session: session)
        XCTAssertEqual(wrongServer, "192.168.1.20:8000 answered, but it isn't the 1DMD server.")

        StubProtocol.answer = .error(URLError(.timedOut))
        let unreachable = await MapService.check(lan, session: session)
        XCTAssertTrue(unreachable?.contains("No answer from 192.168.1.20:8000") == true)
    }
}

private final class StubProtocol: URLProtocol {
    enum Answer { case status(Int), error(URLError) }
    nonisolated(unsafe) static var answer = Answer.status(200)
    nonisolated(unsafe) static var lastURL: URL?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        switch Self.answer {
        case .status(let code):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
