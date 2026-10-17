import XCTest
@testable import OneDMD

final class IntegrationTests: XCTestCase {
    private var base: URL { URL(string: "http://127.0.0.1:8000")! }
    private var audio: URL { FileManager.default.temporaryDirectory.appending(path: "test.wav") }

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
        // Valid mono PCM WAV: 100 ms of silence at 8 kHz.
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        append(UInt32(1636)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(1600))
        wav.append(Data(repeating: 0, count: 1600))
        try wav.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let result = try await MapService.getResults(audioFile: audio, using: ServerBackend(base: base), waitLimit: .seconds(10))
        XCTAssertEqual(result.currentID, "actors")
        XCTAssertEqual(result.nodes.count, 11)
        XCTAssertEqual(result.edges.count, 11)
    }

    func testOfflineServerFailsWithoutRetryingUpload() async throws {
        let offline = URL(string: "http://127.0.0.1:1")!
        try Data("audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            _ = try await MapService.getResults(audioFile: audio, using: ServerBackend(base: offline))
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

    func testPastedTranscriptStillUsesOutlineLayout() throws {
        let json = Data(#"{"current":"n2","nodes":[{"id":"n1","title":"Dune","parent":"","bullets":[{"text":"Actors","talkedAbout":true}]},{"id":"n2","title":"Actors","parent":"n1"}]}"#.utf8)
        let outline = try JSONDecoder().decode(TranscriptOutline.self, from: json)
        let result = NodeMapData(outline)
        XCTAssertEqual(result.currentID, "n2")
        XCTAssertEqual(result.node("n2")?.column, 1)
        XCTAssertEqual(result.edges.count, 1)
    }

    func testMultipartBodyContainsAudioFieldAndExactBytes() throws {
        let payload = Data([0, 1, 2, 255, 13, 10])
        try payload.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let body = try MultipartAudio.create(from: audio)
        defer { try? FileManager.default.removeItem(at: body.url) }
        let bytes = try Data(contentsOf: body.url)
        let headerEnd = try XCTUnwrap(bytes.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertTrue(String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self).contains("name=\"audio\"; filename=\"audio.wav\""))
        XCTAssertEqual(bytes[headerEnd.upperBound..<(headerEnd.upperBound + payload.count)], payload)
        XCTAssertTrue(bytes.suffix(Data("\r\n--\(body.boundary)--\r\n".utf8).count).elementsEqual(Data("\r\n--\(body.boundary)--\r\n".utf8)))
    }

    func testMultipartBodySendsTranscriptBeforeAudio() throws {
        let payload = Data([0, 1, 2, 255])
        try payload.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let transcript = "Uh, yeah, \"JSON\" café\nnext line"
        let body = try MultipartAudio.create(from: audio, transcript: transcript)
        defer { try? FileManager.default.removeItem(at: body.url) }
        let bytes = try Data(contentsOf: body.url)
        let field = Data("Content-Disposition: form-data; name=\"transcript\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(transcript)\r\n--\(body.boundary)\r\n".utf8)
        let fieldRange = try XCTUnwrap(bytes.range(of: field))
        let audioRange = try XCTUnwrap(bytes.range(of: Data("name=\"audio\"".utf8)))
        XCTAssertLessThan(fieldRange.lowerBound, audioRange.lowerBound)
        XCTAssertNotNil(bytes.range(of: payload))
    }

    func testRejectedMultipartFilesDoNotLeaveBodies() throws {
        let directory = FileManager.default.temporaryDirectory
        func bodies() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".multipart") })
        }
        let before = try bodies()
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data().write(to: audio)
        XCTAssertThrowsError(try MultipartAudio.create(from: audio))
        try Data(repeating: 0, count: MultipartAudio.maxBytes + 1).write(to: audio)
        XCTAssertThrowsError(try MultipartAudio.create(from: audio))
        XCTAssertThrowsError(try MultipartAudio.create(from: directory.appending(path: "bad.txt")))
        XCTAssertEqual(try bodies(), before)
    }

    func testUploadDecodesAcceptedJobAndUsesMultipart() async throws {
        try Data("audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let client = ServerBackend(base: base, session: session { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/jobs")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            return (202, Data(#"{"job_id":"abc","status":"queued","status_url":"/jobs/abc"}"#.utf8))
        })
        let accepted = try await client.upload(audio)
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
        let result = try await MapService.getResults(audioFile: audio, using: backend, pollInterval: .milliseconds(1))
        XCTAssertEqual(result.currentID, "actors")
        let counts = await backend.counts
        XCTAssertEqual(counts.uploads, 1)
        XCTAssertEqual(counts.polls, 3)
    }

    func testTerminalFailuresDoNotPollAgain() async throws {
        for status in [JobStatus(status: "failed", error: "processor failed"), JobStatus(status: "completed"), JobStatus(status: "mystery")] {
            let backend = FakeBackend(steps: [.reply(status)])
            do {
                _ = try await MapService.getResults(audioFile: audio, using: backend, pollInterval: .milliseconds(1))
                XCTFail("Expected \(status.status) to fail")
            } catch is MapServiceError { }
            let counts = await backend.counts
            XCTAssertEqual(counts.polls, 1)
            XCTAssertEqual(counts.uploads, 1)
        }
    }

    func testTransientRetryAndRetryExhaustion() async throws {
        let recovered = FakeBackend(steps: [.networkError, .reply(JobStatus(status: "completed", result: try map()))])
        _ = try await MapService.getResults(audioFile: audio, using: recovered, pollInterval: .milliseconds(1))
        let failing = FakeBackend(steps: [.networkError])
        do {
            _ = try await MapService.getResults(audioFile: audio, using: failing, pollInterval: .milliseconds(1), maxRetries: 2)
            XCTFail("Expected retry exhaustion")
        } catch is URLError { }
        let counts = await failing.counts
        XCTAssertEqual(counts.polls, 3)
        XCTAssertEqual(counts.uploads, 1)
    }

    func testDeadlineCoversRetriesAndInFlightRequests() async throws {
        for step in [FakeBackend.Step.networkError, .hang] {
            let backend = FakeBackend(steps: [step])
            let start = ContinuousClock.now
            do {
                _ = try await MapService.getResults(audioFile: audio, using: backend, waitLimit: .milliseconds(50), pollInterval: .milliseconds(1), maxRetries: 100)
                XCTFail("Expected timeout")
            } catch MapServiceError.tookTooLong { }
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testCancellationDuringUploadSleepAndRequest() async throws {
        for mode in 0..<3 {
            let backend = FakeBackend(steps: [.hang], hangUpload: mode == 0)
            let task = Task {
                try await MapService.getResults(audioFile: audio, using: backend, pollInterval: mode == 1 ? .seconds(10) : .milliseconds(1))
            }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            let counts = await backend.counts
            XCTAssertEqual(counts.uploads, 1)
            XCTAssertEqual(counts.polls, mode == 2 ? 1 : 0)
        }
    }

    func testFailedUploadIsNeverRetried() async throws {
        let backend = FakeBackend(steps: [], failUpload: true)
        do {
            _ = try await MapService.getResults(audioFile: audio, using: backend)
            XCTFail("Expected upload failure")
        } catch is URLError { }
        let counts = await backend.counts
        XCTAssertEqual(counts.uploads, 1)
        XCTAssertEqual(counts.polls, 0)
    }
}

private actor FakeBackend: MapBackend {
    enum Step: Sendable { case reply(JobStatus), networkError, hang }
    var steps: [Step]
    let hangUpload: Bool
    let failUpload: Bool
    var counts = (uploads: 0, polls: 0)
    init(steps: [Step], hangUpload: Bool = false, failUpload: Bool = false) {
        self.steps = steps; self.hangUpload = hangUpload; self.failUpload = failUpload
    }
    func upload(_ audio: URL) async throws -> AcceptedJob {
        counts.uploads += 1
        if failUpload { throw URLError(.networkConnectionLost) }
        if hangUpload { try await Task.sleep(for: .seconds(30)) }
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
