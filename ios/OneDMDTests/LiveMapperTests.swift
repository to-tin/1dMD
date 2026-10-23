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
        XCTAssertEqual(mapper.map?.currentID, "a")           // map unchanged
        var count = await fake.requests.count
        XCTAssertEqual(count, 2)                              // no instant retry loop
        await settle(0.3)
        count = await fake.requests.count
        XCTAssertEqual(count, 3)
        let retry = await fake.requests[2]
        XCTAssertEqual(retry.words, "three four")             // words kept
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
