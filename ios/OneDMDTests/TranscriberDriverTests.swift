import XCTest
@testable import OneDMD

/// Stand-in that follows AudioTranscriber's rules: start() ignores a call while preparing or
/// listening; setup can be held open; stop() suspends before it sets the status to idle.
/// It counts setups and records any start/stop that overlaps another.
@MainActor
final class FakeTranscriber: TranscriberControl {
    private(set) var status: AudioTranscriber.Status = .idle
    private(set) var setups = 0
    private(set) var stops = 0
    private(set) var overlaps = 0
    var holdSetup = false
    private var busy = false
    private var gate: CheckedContinuation<Void, Never>?

    func start() async {
        guard status != .preparing, status != .listening else { return }
        enter(); defer { busy = false }
        setups += 1
        status = .preparing
        if holdSetup {
            holdSetup = false
            await withCheckedContinuation { gate = $0 }
        }
        status = .listening
    }

    func stop() async {
        enter(); defer { busy = false }
        stops += 1
        try? await Task.sleep(for: .milliseconds(20))   // like finalizing the analyzer
        status = .idle
    }

    func finishSetup() { gate?.resume(); gate = nil }

    private func enter() {
        if busy { overlaps += 1 }
        busy = true
    }
}

@MainActor
final class TranscriberDriverTests: XCTestCase {
    private let cap: Duration = .milliseconds(100)
    private func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(for: .seconds(seconds)) }

    func testStartThenStop() async {
        let t = FakeTranscriber(), driver = TranscriberDriver()
        driver.start(t)
        await settle(0.05)
        XCTAssertEqual(t.status, .listening)
        await driver.stop(t, waitingAtMost: .seconds(1))
        XCTAssertEqual(t.status, .idle)
        XCTAssertEqual(t.stops, 1)
        XCTAssertEqual(t.overlaps, 0)
    }

    func testStalledSetupDoesNotHangStopAndIsStoppedWhenSetupEnds() async {
        let t = FakeTranscriber(), driver = TranscriberDriver()
        t.holdSetup = true
        driver.start(t)
        await settle(0.05)
        let begin = Date()
        await driver.stop(t, waitingAtMost: cap)
        XCTAssertLessThan(Date().timeIntervalSince(begin), 1.0)   // Stop isn't stuck
        XCTAssertEqual(t.status, .preparing)                       // not stopped mid-setup
        XCTAssertEqual(t.stops, 0)
        t.finishSetup()
        await settle()
        XCTAssertEqual(t.status, .idle)                            // stopped once setup ended
        XCTAssertEqual(t.stops, 1)
        XCTAssertEqual(t.overlaps, 0)
    }

    func testStopStartStopDuringOneSetupEndsNotListening() async {
        let t = FakeTranscriber(), driver = TranscriberDriver()
        t.holdSetup = true
        driver.start(t)
        await settle(0.05)
        await driver.stop(t, waitingAtMost: cap)
        driver.start(t)
        await driver.stop(t, waitingAtMost: cap)
        t.finishSetup()
        await settle()
        XCTAssertEqual(t.status, .idle)
        XCTAssertEqual(t.setups, 1)                                // the stale Start didn't start
        XCTAssertEqual(t.overlaps, 0)
    }

    func testStartStopStartStartGivesOneSessionThatKeepsListening() async {
        let t = FakeTranscriber(), driver = TranscriberDriver()
        t.holdSetup = true
        driver.start(t)
        await settle(0.05)
        await driver.stop(t, waitingAtMost: cap)
        driver.start(t)
        driver.start(t)
        t.finishSetup()
        await settle()
        XCTAssertEqual(t.status, .listening)
        XCTAssertEqual(t.setups, 1)                                // exactly one setup/analyzer
        XCTAssertEqual(t.stops, 0)                                 // the stale Stop didn't stop it
        XCTAssertEqual(t.overlaps, 0)
    }

    func testRecordingAgainAfterAStopStartsAFreshSession() async {
        let t = FakeTranscriber(), driver = TranscriberDriver()
        driver.start(t)
        await settle(0.05)
        await driver.stop(t, waitingAtMost: .seconds(1))
        driver.start(t)
        await settle(0.1)
        XCTAssertEqual(t.status, .listening)
        XCTAssertEqual(t.setups, 2)
        XCTAssertEqual(t.stops, 1)
        XCTAssertEqual(t.overlaps, 0)
    }

    func testRapidTogglingNeverOverlapsAndFollowsTheLastPress() async {
        let t = FakeTranscriber(), driver = TranscriberDriver()
        for _ in 0..<5 {
            driver.start(t)
            await driver.stop(t, waitingAtMost: .zero)
        }
        driver.start(t)
        await settle(0.5)
        XCTAssertEqual(t.status, .listening)
        XCTAssertEqual(t.setups, 1)        // presses that were already undone never started
        XCTAssertEqual(t.overlaps, 0)
    }
}
