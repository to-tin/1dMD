import Foundation

/// Explicit offline stand-in selected with `-usePlaceholderBackend YES`. Hands out a job id,
/// says "queued" then "processing" for a few checks, then "completed" with `PlaceholderMap.json`.
///
/// To test what happens when things go wrong, add `-mapScenario <name>` to the Xcode scheme
/// (Product › Scheme › Edit Scheme › Run › Arguments). Debug builds only.
actor PlaceholderBackend: MapBackend, LiveBackend {
    static let shared = PlaceholderBackend()

    enum Scenario: String {
        /// Normal run: the map arrives after a few checks.
        case success
        /// The server reports that the job failed.
        case failed
        /// The job never finishes (pair with `-mapMaxWait 15` to see the timeout quickly).
        case neverFinishes
        /// One check drops out mid-way; the app should retry and carry on without an error.
        case networkBlip
        /// The server uses a status word the app doesn't know.
        case badReply
    }

    /// Checks needed before the job is "completed".
    private let checksUntilDone = 3
    private var checks: [String: Int] = [:]

    private var scenario: Scenario {
        #if DEBUG
        UserDefaults.standard.string(forKey: "mapScenario").flatMap(Scenario.init) ?? .success
        #else
        .success
        #endif
    }

    func submit(_ payload: TranscriptRequest) async throws -> AcceptedJob {
        try await Task.sleep(for: .seconds(0.5))
        let jobId = "placeholder-\(UUID().uuidString.prefix(8))"
        checks[jobId] = 0
        return AcceptedJob(id: jobId, statusURL: MapService.serverURL.appending(path: "jobs").appending(path: jobId))
    }

    func status(of job: AcceptedJob) async throws -> JobStatus {
        let jobId = job.id
        guard let count = checks[jobId] else { throw MapServiceError.jobLost }
        checks[jobId] = count + 1

        if scenario == .networkBlip, count == 1 { throw URLError(.networkConnectionLost) }
        if count == 0 { return JobStatus(status: "queued") }
        if count < checksUntilDone || scenario == .neverFinishes { return JobStatus(status: "processing") }

        checks[jobId] = nil
        switch scenario {
        case .failed:
            return JobStatus(status: "failed", error: "The stand-in server pretended it couldn't map the transcript.")
        case .badReply:
            return JobStatus(status: "complete")
        case .success, .networkBlip, .neverFinishes:
            return JobStatus(status: "completed", result: NodeMapData(try Self.placeholderMap()))
        }
    }

    private static func placeholderMap() throws -> TranscriptOutline {
        guard let url = Bundle.main.url(forResource: "PlaceholderMap", withExtension: "json") else {
            throw MapServiceError.missingPlaceholder
        }
        return try JSONDecoder().decode(TranscriptOutline.self, from: Data(contentsOf: url))
    }

    /// Live stand-in: each call shows one more step of `NodeMapData.sample` than the request's
    /// outline already has. The step comes from the outline's node count, so it keeps no state
    /// and works with a continued chat. `-mapScenario failed` makes it throw.
    func update(_ request: LiveRequest) async throws -> LiveReply {
        try await Task.sleep(for: .seconds(Double.random(in: 0.3...0.6)))
        if scenario == .failed { throw URLError(.cannotConnectToHost) }

        let sample = NodeMapData.sample
        let have = request.outline?.nodes.count ?? 0
        // Smallest step that shows more nodes than the outline has; the full sample if none does.
        let step = (0...sample.edges.count).first { sample.revealed(steps: $0).nodes.count > have }
        guard let step else {
            var full = sample
            full.outline = MapOutline(rebuildingFrom: full)
            return LiveReply(map: full, move: "none")
        }
        var map = sample.revealed(steps: step)
        map.outline = MapOutline(rebuildingFrom: map)
        let move: String
        switch step == 0 ? nil : sample.edges[step - 1].kind {
        case .deeper: move = "deeper"
        case .newTopic, nil: move = "new"
        default: move = "stay"
        }
        return LiveReply(map: map, move: move)
    }
}
