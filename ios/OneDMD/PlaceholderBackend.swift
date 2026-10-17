import Foundation

/// Stands in for the server until it exists. Behaves like the real one: hands out a job id,
/// says "queued" then "processing" for a few checks, then "done" with `PlaceholderMap.json`.
///
/// To test what happens when things go wrong, add `-mapScenario <name>` to the Xcode scheme
/// (Product › Scheme › Edit Scheme › Run › Arguments). Debug builds only.
actor PlaceholderBackend: MapBackend {
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

    /// Checks needed before the job is "done".
    private let checksUntilDone = 3
    private var checks: [String: Int] = [:]

    private var scenario: Scenario {
        #if DEBUG
        UserDefaults.standard.string(forKey: "mapScenario").flatMap(Scenario.init) ?? .success
        #else
        .success
        #endif
    }

    func upload(_ audio: URL) async throws -> String {
        try await Task.sleep(for: .seconds(0.5))
        let jobId = "placeholder-\(UUID().uuidString.prefix(8))"
        checks[jobId] = 0
        return jobId
    }

    func status(of jobId: String) async throws -> JobStatus {
        guard let count = checks[jobId] else { throw MapServiceError.jobLost }
        checks[jobId] = count + 1

        if scenario == .networkBlip, count == 1 { throw URLError(.networkConnectionLost) }
        if count == 0 { return JobStatus(status: "queued") }
        if count < checksUntilDone || scenario == .neverFinishes { return JobStatus(status: "processing") }

        checks[jobId] = nil
        switch scenario {
        case .failed:
            return JobStatus(status: "failed", error: "The stand-in server pretended it couldn't hear the audio.")
        case .badReply:
            return JobStatus(status: "complete")
        case .success, .networkBlip, .neverFinishes:
            return JobStatus(status: "done", result: try Self.placeholderMap())
        }
    }

    private static func placeholderMap() throws -> TranscriptOutline {
        guard let url = Bundle.main.url(forResource: "PlaceholderMap", withExtension: "json") else {
            throw MapServiceError.missingPlaceholder
        }
        return try JSONDecoder().decode(TranscriptOutline.self, from: Data(contentsOf: url))
    }
}
