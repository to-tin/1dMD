import XCTest
@testable import OneDMD

final class ChatStoreTests: XCTestCase {
    private var folder: URL!
    private var store: ChatStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "ChatStoreTests-\(UUID().uuidString)")
        store = ChatStore(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testEmptyWhenNothingSaved() {
        XCTAssertTrue(store.all().isEmpty)
    }

    func testSavedChatComesBackWithItsWholeMap() throws {
        let map = NodeMapData.sample
        let chat = SavedChat(transcript: "We talked about Dune.", map: map)
        try store.save(chat)

        let loaded = try XCTUnwrap(store.all().first)
        XCTAssertEqual(loaded.id, chat.id)
        XCTAssertEqual(loaded.title, "Dune")
        XCTAssertEqual(loaded.transcript, "We talked about Dune.")
        XCTAssertNil(loaded.duration)
        XCTAssertEqual(loaded.topicCount, 2)

        let saved = try XCTUnwrap(loaded.map)
        XCTAssertEqual(saved.currentID, map.currentID)
        XCTAssertEqual(saved.nodes.map(\.id), map.nodes.map(\.id))
        XCTAssertEqual(saved.nodes.map(\.title), map.nodes.map(\.title))
        XCTAssertEqual(saved.nodes.map(\.line), map.nodes.map(\.line))
        XCTAssertEqual(saved.nodes.map(\.column), map.nodes.map(\.column))
        XCTAssertEqual(saved.nodes.map(\.branch), map.nodes.map(\.branch))
        XCTAssertEqual(saved.nodes.flatMap(\.bullets).map(\.text), map.nodes.flatMap(\.bullets).map(\.text))
        XCTAssertEqual(saved.nodes.flatMap(\.bullets).map(\.branch), map.nodes.flatMap(\.bullets).map(\.branch))
        XCTAssertEqual(saved.nodes.flatMap(\.bullets).map(\.isFilled), map.nodes.flatMap(\.bullets).map(\.isFilled))
        XCTAssertEqual(saved.edges.map(\.id), map.edges.map(\.id))
        XCTAssertEqual(saved.edges.map(\.kind), map.edges.map(\.kind))
    }

    func testBranchColoursAreSavedByName() throws {
        try store.save(SavedChat(transcript: "x", map: .sample))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"purple\""))
        XCTAssertTrue(text.contains("\"deeper\""))
    }

    func testContinuingUpdatesTheSameChat() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var chat = SavedChat(transcript: "", now: start)
        chat.append(words: "First part.", recorded: 90, now: start)
        try store.save(chat)

        chat.append(words: "Second part.", recorded: 30, now: start.addingTimeInterval(3600))
        try store.save(chat)

        let all = store.all()
        XCTAssertEqual(all.count, 1)
        let loaded = try XCTUnwrap(all.first)
        XCTAssertEqual(loaded.transcript, "First part.\n\nSecond part.")
        XCTAssertEqual(loaded.duration, 120)
        XCTAssertEqual(loaded.date, start)
        XCTAssertEqual(loaded.updated, start.addingTimeInterval(3600))
    }

    func testTitleIsKeptOnceSet() {
        var chat = SavedChat(transcript: "x", map: .sample)
        XCTAssertEqual(chat.title, "Dune")
        var other = NodeMapData.sample
        other.nodes[0].title = "Something else"
        chat.setMap(other)
        XCTAssertEqual(chat.title, "Dune")
    }

    func testNewestUpdatedFirst() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var old = SavedChat(transcript: "old", now: base)
        let new = SavedChat(transcript: "new", now: base.addingTimeInterval(60))
        try store.save(old)
        try store.save(new)
        XCTAssertEqual(store.all().map(\.transcript), ["new", "old"])

        old.append(words: "more", recorded: 5, now: base.addingTimeInterval(120))
        try store.save(old)
        XCTAssertEqual(store.all().map(\.id), [old.id, new.id])
    }

    func testDeleteRemovesOnlyThatChat() throws {
        let a = SavedChat(transcript: "a")
        let b = SavedChat(transcript: "b")
        try store.save(a)
        try store.save(b)
        try store.delete(a.id)
        XCTAssertEqual(store.all().map(\.id), [b.id])
        // Deleting something already gone is fine.
        XCTAssertNoThrow(try store.delete(a.id))
    }

    func testUnreadableFileIsSkippedAndKept() throws {
        let good = SavedChat(transcript: "good")
        try store.save(good)
        let broken = folder.appending(path: "\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: broken)

        XCTAssertEqual(store.all().map(\.id), [good.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }

    func testOutlineSavedWithTheMap() throws {
        var map = NodeMapData.sample
        map.outline = MapOutline(nodes: [.init(id: "dune", title: "Dune", parent: "", continues: "",
                                               description: "About Dune.", bullets: [.init(text: "Worms", talkedAbout: true)])],
                                 current: "dune")
        try store.save(SavedChat(transcript: "x", map: map))
        XCTAssertEqual(try XCTUnwrap(store.all().first).map?.outline, map.outline)
    }

    func testChatSavedBeforeOutlinesStillLoads() throws {
        var chat = SavedChat(transcript: "x", map: .sample)
        chat.map?.outline = nil
        try store.save(chat)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("outline"))
        XCTAssertNil(try XCTUnwrap(store.all().first).map?.outline)
    }

    func testOutlineRebuiltFromOldMap() throws {
        let rebuilt = try XCTUnwrap(NodeMapData.sample.liveOutline)
        XCTAssertEqual(rebuilt.current, "pizza")
        XCTAssertEqual(rebuilt.nodes.map(\.id), NodeMapData.sample.nodes.map(\.id))
        let pizza = try XCTUnwrap(rebuilt.nodes.first { $0.id == "pizza" })
        XCTAssertEqual(pizza.parent, "nyc")
        let dune = try XCTUnwrap(rebuilt.nodes.first { $0.id == "dune" })
        XCTAssertEqual(dune.bullets.map(\.text), ["Worms", "Spice", "Politics"])
        XCTAssertEqual(dune.bullets.map(\.talkedAbout), [true, false, false])
        XCTAssertNil(NodeMapData.empty.liveOutline)
    }

    func testServerOutlineDecodes() throws {
        let json = #"{"currentID":"a","nodes":[{"id":"a","title":"A","isTopic":true,"line":0,"column":0,"bullets":[]}],"edges":[],"outline":{"nodes":[{"id":"a","title":"A","parent":"","continues":"","description":"d","bullets":[{"text":"x","talked_about":false}]}],"current":"a"}}"#
        let map = try JSONDecoder().decode(ServerMap.self, from: Data(json.utf8)).mapData()
        XCTAssertEqual(map.outline?.nodes.first?.bullets.first, .init(text: "x", talkedAbout: false))
    }
}
