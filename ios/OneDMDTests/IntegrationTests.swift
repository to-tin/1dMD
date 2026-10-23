import XCTest
@testable import OneDMD

final class IntegrationTests: XCTestCase {
    private var base: URL { URL(string: "http://127.0.0.1:8000")! }
    private let transcript = "A conversation about Dune and its actors."

    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "mock_response_body", withExtension: "json")))
    }

    private func map() throws -> NodeMapData {
        try JSONDecoder().decode(ServerMap.self, from: fixture()).mapData()
    }

    private func session(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        StubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Optional end-to-end check: run ./1dmd start before Product → Test.
    func testLiveLocalPythonServer() async throws {
        var health = URLRequest(url: base.appending(path: "health"))
        health.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: health)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  String(decoding: data, as: UTF8.self).contains("ok") else {
                throw XCTSkip("Start ./1dmd start on port 8000 for the live-server check.")
            }
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .timedOut {
            throw XCTSkip("Start ./1dmd start on port 8000 for the live-server check.")
        }
        // The server returns the mock map without an API key and a real Claude map with one,
        // so check that the map is valid rather than which map it is. getResults already
        // rejects a map the app can't draw. Claude can take several seconds.
        let result = try await MapService.getResults(transcript: transcript, using: ServerBackend(base: base), waitLimit: .seconds(60))
        XCTAssertFalse(result.topics.isEmpty)
        let current = try XCTUnwrap(result.currentID)
        XCTAssertNotNil(result.node(current))
    }

    func testOfflineServerFailsWithoutRetryingSubmission() async throws {
        let offline = URL(string: "http://127.0.0.1:1")!
        do {
            _ = try await MapService.getResults(transcript: transcript, using: ServerBackend(base: offline))
            XCTFail("Expected an offline-server error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }

    func testActualBackendGraphPreservesLayoutAndCurrentTopic() throws {
        let result = try map()
        XCTAssertEqual(result.nodes.count, 11)
        XCTAssertEqual(result.edges.count, 11)
        XCTAssertEqual(result.currentID, "actors")
        let actors = try XCTUnwrap(result.node("actors"))
        XCTAssertEqual(actors.title, "Actors")
        XCTAssertEqual(actors.line, 4)
        XCTAssertEqual(actors.column, 1)
        XCTAssertEqual(actors.branch, .rose)
        XCTAssertFalse(actors.isTopic)
        XCTAssertEqual(actors.bullets.map(\.text), ["Chalamet", "Zendaya"])
        XCTAssertFalse(actors.bullets[0].talkedAbout)
        XCTAssertEqual(result.node("dune-cont")?.isContinued, true)
        XCTAssertEqual(result.node("dune")?.isContinued, false)
        XCTAssertEqual(result.node("dune")?.bullets[0].branch, .purple)
        XCTAssertTrue(result.edges.contains { $0.from == "dune" && $0.to == "dune-cont" && $0.kind == .continued })
    }

    func testMalformedGraphsAreRejected() throws {
        let valid = try JSONDecoder().decode(ServerMap.self, from: fixture())
        var bad = valid
        bad.nodes.append(bad.nodes[0])
        XCTAssertThrowsError(try bad.mapData())
        bad = valid; bad.currentID = "missing"
        XCTAssertThrowsError(try bad.mapData())
        bad = valid; bad.edges[0].to = "missing"
        XCTAssertThrowsError(try bad.mapData())
        bad = valid; bad.edges[0].kind = "unknown"
        XCTAssertThrowsError(try bad.mapData())
        bad = valid; bad.nodes[0].branch = "unknown"
        XCTAssertThrowsError(try bad.mapData())
        bad = valid; bad.nodes[0].line = -1
        XCTAssertThrowsError(try bad.mapData())
        bad = valid; bad.nodes = []
        XCTAssertThrowsError(try bad.mapData())
    }

    func testDebugPlaceholderOutlineLayout() throws {
        let json = Data(#"{"current":"n2","nodes":[{"id":"n1","title":"Dune","parent":"","bullets":[{"text":"Actors","talkedAbout":true}]},{"id":"n2","title":"Actors","parent":"n1"}]}"#.utf8)
        let outline = try JSONDecoder().decode(TranscriptOutline.self, from: json)
        let result = NodeMapData(outline)
        XCTAssertEqual(result.currentID, "n2")
        XCTAssertEqual(result.node("n2")?.column, 1)
        XCTAssertEqual(result.edges.count, 1)
    }

    func testSubmitDecodesAcceptedJobAndSendsTranscriptJSON() async throws {
        let text = "  Speaker: \"Hello\"\n你好 🎬  "
        let client = ServerBackend(base: base, session: session { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/jobs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            // URLSession may expose a streamed body to URLProtocol even for httpBody.
            let body: Data
            if let data = request.httpBody {
                body = data
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(object, ["transcript": text])
            return (202, Data(#"{"job_id":"abc","status":"queued","status_url":"/jobs/abc"}"#.utf8))
        })
        let accepted = try await client.submit(TranscriptRequest(transcript: text))
        XCTAssertEqual(accepted.id, "abc")
        XCTAssertEqual(accepted.statusURL.absoluteString, "http://127.0.0.1:8000/jobs/abc")
    }

    func testHTTPCompletedResponseUsesActualFixture() async throws {
        let graph = String(decoding: try fixture(), as: UTF8.self)
        let client = ServerBackend(base: base, session: session { request in
            XCTAssertEqual(request.url?.path, "/jobs/abc")
            return (200, Data("{\"job_id\":\"abc\",\"status\":\"completed\",\"result\":\(graph),\"error\":null}".utf8))
        })
        let status = try await client.status(of: AcceptedJob(id: "abc", statusURL: base.appending(path: "jobs/abc")))
        XCTAssertEqual(status.status, "completed")
        XCTAssertEqual(status.result?.currentID, "actors")
    }

    func testHTTPFailuresAndMalformedResponses() async throws {
        for (code, body) in [(404, "missing"), (413, "large"), (500, "error"), (200, "not JSON"), (200, #"{"job_id":"wrong","status":"queued"}"#)] {
            let client = ServerBackend(base: base, session: session { _ in (code, Data(body.utf8)) })
            do {
                _ = try await client.status(of: AcceptedJob(id: "abc", statusURL: base.appending(path: "jobs/abc")))
                XCTFail("Expected failure for \(code): \(body)")
            } catch let error as MapServiceError {
                switch (code, error) {
                case (404, .jobLost), (413, .tooLarge), (500, .server), (200, .badReply): break
                default: XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testPollsQueuedAndProcessingThenCompletes() async throws {
        let backend = FakeBackend(steps: [.reply(JobStatus(status: "queued")), .reply(JobStatus(status: "processing")), .reply(JobStatus(status: "completed", result: try map()))])
        let result = try await MapService.getResults(transcript: transcript, using: backend, pollInterval: .milliseconds(1))
        XCTAssertEqual(result.currentID, "actors")
        let counts = await backend.counts
        XCTAssertEqual(counts.submissions, 1)
        XCTAssertEqual(counts.polls, 3)
        let received = await backend.receivedTranscript
        XCTAssertEqual(received, transcript)
    }

    func testTerminalFailuresDoNotPollAgain() async throws {
        for status in [JobStatus(status: "failed", error: "processor failed"), JobStatus(status: "completed"), JobStatus(status: "mystery")] {
            let backend = FakeBackend(steps: [.reply(status)])
            do {
                _ = try await MapService.getResults(transcript: transcript, using: backend, pollInterval: .milliseconds(1))
                XCTFail("Expected \(status.status) to fail")
            } catch is MapServiceError { }
            let counts = await backend.counts
            XCTAssertEqual(counts.polls, 1)
            XCTAssertEqual(counts.submissions, 1)
        }
    }

    func testTransientRetryAndRetryExhaustion() async throws {
        let recovered = FakeBackend(steps: [.networkError, .reply(JobStatus(status: "completed", result: try map()))])
        _ = try await MapService.getResults(transcript: transcript, using: recovered, pollInterval: .milliseconds(1))
        let failing = FakeBackend(steps: [.networkError])
        do {
            _ = try await MapService.getResults(transcript: transcript, using: failing, pollInterval: .milliseconds(1), maxRetries: 2)
            XCTFail("Expected retry exhaustion")
        } catch is URLError { }
        let counts = await failing.counts
        XCTAssertEqual(counts.polls, 3)
        XCTAssertEqual(counts.submissions, 1)
    }

    func testDeadlineCoversRetriesAndInFlightRequests() async throws {
        for step in [FakeBackend.Step.networkError, .hang] {
            let backend = FakeBackend(steps: [step])
            let start = ContinuousClock.now
            do {
                _ = try await MapService.getResults(transcript: transcript, using: backend, waitLimit: .milliseconds(50), pollInterval: .milliseconds(1), maxRetries: 100)
                XCTFail("Expected timeout")
            } catch MapServiceError.tookTooLong { }
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testCancellationDuringSubmissionSleepAndRequest() async throws {
        for mode in 0..<3 {
            let backend = FakeBackend(steps: [.hang], hangSubmission: mode == 0)
            let task = Task {
                try await MapService.getResults(transcript: transcript, using: backend, pollInterval: mode == 1 ? .seconds(10) : .milliseconds(1))
            }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            let counts = await backend.counts
            XCTAssertEqual(counts.submissions, 1)
            XCTAssertEqual(counts.polls, mode == 2 ? 1 : 0)
        }
    }

    func testFailedSubmissionIsNeverRetried() async throws {
        let backend = FakeBackend(steps: [], failSubmission: true)
        do {
            _ = try await MapService.getResults(transcript: transcript, using: backend)
            XCTFail("Expected submission failure")
        } catch is URLError { }
        let counts = await backend.counts
        XCTAssertEqual(counts.submissions, 1)
        XCTAssertEqual(counts.polls, 0)
    }

    func testServerAddressSetting() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: MapService.serverAddressKey) }
        defaults.removeObject(forKey: MapService.serverAddressKey)
        XCTAssertEqual(MapService.serverURL.absoluteString, "http://127.0.0.1:8000")
        defaults.set(" http://192.168.1.23:8000 ", forKey: MapService.serverAddressKey)
        XCTAssertEqual(MapService.serverURL.absoluteString, "http://192.168.1.23:8000")
        defaults.set("not a url", forKey: MapService.serverAddressKey)
        XCTAssertEqual(MapService.serverURL.absoluteString, "http://127.0.0.1:8000")
    }
}

private actor FakeBackend: MapBackend {
    enum Step: Sendable { case reply(JobStatus), networkError, hang }
    var steps: [Step]
    let hangSubmission: Bool
    let failSubmission: Bool
    var counts = (submissions: 0, polls: 0)
    var receivedTranscript: String?
    init(steps: [Step], hangSubmission: Bool = false, failSubmission: Bool = false) {
        self.steps = steps; self.hangSubmission = hangSubmission; self.failSubmission = failSubmission
    }
    func submit(_ payload: TranscriptRequest) async throws -> AcceptedJob {
        counts.submissions += 1
        receivedTranscript = payload.transcript
        if failSubmission { throw URLError(.networkConnectionLost) }
        if hangSubmission { try await Task.sleep(for: .seconds(30)) }
        return AcceptedJob(id: "abc", statusURL: URL(string: "http://127.0.0.1:8000/jobs/abc")!)
    }
    func status(of job: AcceptedJob) async throws -> JobStatus {
        counts.polls += 1
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        switch step {
        case .reply(let result): return result
        case .networkError: throw URLError(.networkConnectionLost)
        case .hang:
            try await Task.sleep(for: .seconds(30))
            return JobStatus(status: "processing")
        }
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
