import SwiftUI
import XCTest
@testable import OneDMD

/// Tap a node to see its description: the data path and the card heights.
final class NodeDescriptionTests: XCTestCase {
    private func node(bullets: Int = 2, description: String? = nil) -> MapNode {
        MapNode(id: "a", title: "A", bullets: (0..<bullets).map { MapBullet(text: "b\($0)") },
                line: 0, column: 0, isTopic: true, description: description)
    }

    private let short = "A short note."
    private let long = "A much longer description that goes on about what was said, why it came up, "
        + "and where the conversation went next, so it has to wrap over several lines."

    // MARK: Heights

    func testCollapsedHeightIsUnchanged() {
        // padY * 2 + rowHeight * (title + 2 bullets) + titleGap, exactly as before.
        XCTAssertEqual(MapLayout.height(node()), 14 * 2 + 22 * 3 + 4)
        XCTAssertEqual(MapLayout.height(node(bullets: 0)), 14 * 2 + 22)
    }

    func testNoDescriptionIgnoresExpanded() {
        XCTAssertEqual(MapLayout.height(node(), expanded: true), MapLayout.height(node()))
        XCTAssertEqual(MapLayout.height(node(description: ""), expanded: true), MapLayout.height(node()))
    }

    func testCollapsedWithDescriptionMatchesWithout() {
        XCTAssertEqual(MapLayout.height(node(description: short)), MapLayout.height(node()))
        XCTAssertEqual(MapLayout.height(node(description: long), expanded: false), MapLayout.height(node()))
    }

    func testExpandedGrowsWithTheText() {
        let collapsed = MapLayout.height(node())
        let shortH = MapLayout.height(node(description: short), expanded: true)
        let longH = MapLayout.height(node(description: long), expanded: true)
        XCTAssertGreaterThan(shortH, collapsed)
        XCTAssertGreaterThan(longH, shortH)
        // The long one wraps: at least three lines more than the one-line short one.
        let line = MapLayout.descriptionHeight(short)
        XCTAssertGreaterThanOrEqual(longH - shortH, line * 2)
    }

    /// The measured height must match what SwiftUI actually draws, or the card clips the
    /// last line. Includes strings whose last line is one short word.
    @MainActor
    func testMeasuredHeightMatchesSwiftUI() {
        var texts = [
            long,
            "Why the team picked the smaller office: cheaper rent, closer to the train, and a quiet room for calls. It",
            "They argued about whether pineapple belongs on pizza and never settled it, so it stays open. Ok.",
            "Started with weekend plans, drifted into a long story about a broken car and the mechanic who fixed it for free. So",
            "A list: bread, milk, eggs, coffee, apples, cheese, tomatoes, onions, rice, and a big bag of dog food. Yes.",
        ]
        // A sweep of the long text cut at every word, so many different last lines are checked.
        let words = (long + " " + texts[3]).split(separator: " ")
        for n in stride(from: 4, through: words.count, by: 1) { texts.append(words.prefix(n).joined(separator: " ")) }
        // Deterministic pseudo-random sentences of mixed word lengths.
        let pool = ["a", "it", "so", "the", "and", "talk", "about", "pizza", "really", "weekend", "mechanic",
                    "conversation", "I", "ok", "went", "we", "because", "unbelievable", "x", "plans."]
        var seed: UInt64 = 42
        for _ in 0..<400 {
            var sentence: [String] = []
            for _ in 0..<(8 + Int(seed % 30)) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                sentence.append(pool[Int((seed >> 33) % UInt64(pool.count))])
            }
            texts.append(sentence.joined(separator: " "))
        }
        var mismatches: [String] = []
        for text in texts {
            let host = UIHostingController(rootView: Text(text).font(MapStyle.bulletFont)
                .fixedSize(horizontal: false, vertical: true).frame(width: MapLayout.textWidth))
            let drawn = host.sizeThatFits(in: CGSize(width: MapLayout.textWidth, height: .greatestFiniteMagnitude)).height
            let measured = MapLayout.descriptionHeight(text)
            // Never shorter than what's drawn (that clips), and never a whole line taller.
            if measured < drawn || measured - drawn > 6 { mismatches.append("measured \(measured) drawn \(drawn): \(text)") }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testExpandingPushesTheNodeBelowDown() throws {
        var data = NodeMapData.sample
        data.nodes[0].description = long
        let closed = MapLayout(data)
        let open = MapLayout(data, expanded: ["dune"])
        let grow = try XCTUnwrap(open.frame("dune")).height - XCTUnwrap(closed.frame("dune")).height
        XCTAssertGreaterThan(grow, 0)
        XCTAssertEqual(try XCTUnwrap(open.frame("worms")).minY, try XCTUnwrap(closed.frame("worms")).minY + grow)
        // Other columns don't move.
        XCTAssertEqual(open.frame("nyc"), closed.frame("nyc"))
    }

    // MARK: Data

    func testServerDescriptionDecodes() throws {
        let json = #"{"currentID":"a","nodes":["#
            + #"{"id":"a","title":"A","isTopic":true,"line":0,"column":0,"bullets":[],"description":"About A."},"#
            + #"{"id":"b","title":"B","isTopic":true,"line":1,"column":0,"bullets":[],"description":"  "},"#
            + #"{"id":"c","title":"C","isTopic":true,"line":2,"column":0,"bullets":[]}],"edges":[]}"#
        let map = try JSONDecoder().decode(ServerMap.self, from: Data(json.utf8)).mapData()
        XCTAssertEqual(map.nodes.map(\.description), ["About A.", nil, nil])
    }

    func testOldSavedNodeStillLoads() throws {
        let json = #"{"id":"a","title":"A","bullets":[],"line":0,"column":0,"isTopic":true,"isContinued":false}"#
        XCTAssertNil(try JSONDecoder().decode(MapNode.self, from: Data(json.utf8)).description)
    }

    func testDescriptionSurvivesSaving() throws {
        let saved = try JSONEncoder().encode(node(description: short))
        XCTAssertEqual(try JSONDecoder().decode(MapNode.self, from: saved).description, short)
    }

    func testRebuiltOutlineCarriesDescription() throws {
        var data = NodeMapData.sample
        data.outline = nil
        data.nodes[0].description = short
        data.nodes[1].description = nil
        let outline = try XCTUnwrap(data.liveOutline)
        XCTAssertEqual(outline.nodes[0].description, short)
        XCTAssertEqual(outline.nodes[1].description, "")
    }

    func testSampleHasDescriptions() {
        XCTAssertGreaterThan(NodeMapData.sample.nodes.filter { $0.description != nil }.count,
                             NodeMapData.sample.nodes.count / 2)
    }
}

/// The NOW line shown while recording: the current topic and the path that led to it.
final class GlanceTests: XCTestCase {
    func testPathRunsFromTheTopicDown() {
        let titles = NodeMapData.sample.path(to: "friend").map(\.title)
        XCTAssertEqual(titles, ["New York", "Columbia", "My friend"])
    }

    func testPathOfATopicIsJustTheTopic() {
        XCTAssertEqual(NodeMapData.sample.path(to: "nyc").map(\.id), ["nyc"])
    }

    func testPathOfNothingIsEmpty() {
        XCTAssertTrue(NodeMapData.sample.path(to: nil).isEmpty)
        XCTAssertTrue(NodeMapData.sample.path(to: "missing").isEmpty)
    }

    func testPathStopsAtALoop() {
        var data = NodeMapData.sample
        data.edges.append(MapEdge(from: "pizza", to: "nyc", kind: .deeper))
        XCTAssertEqual(data.path(to: "pizza").map(\.id), ["nyc", "pizza"])
    }
}
