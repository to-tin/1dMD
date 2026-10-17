import UIKit

/// The one place an uploaded audio file goes to become a map.
///
/// `getResults` follows the agreed flow: upload the audio and get a job id, keep asking the
/// server whether that job is done, then turn the finished JSON into a map.
///
/// Until the server exists, `serverURL` is nil and `PlaceholderBackend` stands in for it,
/// going through exactly the same steps. The server contract is in READMEBACKEND.md.
enum MapService {
    // MARK: Settings

    /// The server's address, e.g. `https://api.example.com`. `nil` uses the stand-in.
    static let serverURL: URL? = nil

    /// Give up on a job after this long.
    static var maxWait: Duration {
        #if DEBUG
        // `-mapMaxWait 15` in the Xcode scheme shortens it for testing.
        let override = UserDefaults.standard.integer(forKey: "mapMaxWait")
        if override > 0 { return .seconds(override) }
        #endif
        return .seconds(600)
    }

    /// How many checks in a row may fail on a flaky connection before giving up.
    static let maxRetries = 5

    static var backend: MapBackend {
        if let serverURL { ServerBackend(base: serverURL) } else { PlaceholderBackend.shared }
    }

    // MARK: getResults

    static func getResults(
        audioFile: URL,
        onStage: @escaping @MainActor (MapStage) -> Void = { _ in }
    ) async throws -> NodeMapData {
        let backend = self.backend

        // 1. Upload the audio and get a job id. Not retried: a retry could start a duplicate job.
        await onStage(.uploading)
        let jobId = try await keepingAppAwake { try await backend.upload(audioFile) }

        // 2. Keep asking until the job is done. Wait a little longer between each check.
        await onStage(.waiting)
        let deadline = ContinuousClock.now + maxWait
        var delay = Duration.seconds(1)
        var failures = 0

        while true {
            try await Task.sleep(for: delay)

            let job: JobStatus
            do {
                job = try await backend.status(of: jobId)
                failures = 0
            } catch where isTemporary(error) && failures < maxRetries {
                failures += 1
                delay = min(delay * 2, .seconds(15))
                continue
            }

            switch job.status {
            case "queued", "processing":
                delay = min(delay + .seconds(1), .seconds(5))

            // 3. Turn the finished JSON into a map.
            case "done":
                guard let result = job.result else { throw MapServiceError.doneWithoutMap }
                await onStage(.drawing)
                let map = NodeMapData(result)
                guard !map.nodes.isEmpty else { throw MapServiceError.noTopics }
                return map

            case "failed":
                throw MapServiceError.jobFailed(job.error)

            default:
                throw MapServiceError.unknownStatus(job.status)
            }

            // Checked after a real check, so a job that finished while the app was away still shows.
            if ContinuousClock.now > deadline { throw MapServiceError.tookTooLong }
        }
    }

    /// Network hiccups worth trying again, as opposed to real answers from the server.
    private static func isTemporary(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        if case .server(let status, _) = error as? MapServiceError {
            return [429, 502, 503, 504].contains(status)
        }
        return false
    }

    /// Asks iOS for extra time so an upload isn't cut off if the user leaves the app.
    @MainActor
    private static func keepingAppAwake<T>(_ work: () async throws -> T) async rethrows -> T {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Upload audio") {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        defer { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
        return try await work()
    }
}

// MARK: - Types

/// What sits behind `getResults`: the stand-in today, the real server later.
protocol MapBackend: Sendable {
    /// Sends the audio and returns the job id.
    func upload(_ audio: URL) async throws -> String
    /// Asks how the job is going.
    func status(of jobId: String) async throws -> JobStatus
}

/// The server's answer to "is job X done?".
struct JobStatus: Decodable {
    /// "queued", "processing", "done" or "failed". Kept as text so an unexpected word shows up in the error.
    var status: String
    /// The map JSON, once `status` is "done".
    var result: TranscriptOutline? = nil
    /// Why it failed, once `status` is "failed".
    var error: String? = nil
}

/// What the "Making map…" badge says.
enum MapStage: Equatable {
    case uploading, waiting, drawing

    var label: String {
        switch self {
        case .uploading: "Uploading…"
        case .waiting: "Waiting for the map…"
        case .drawing: "Making map…"
        }
    }
}

enum MapServiceError: LocalizedError {
    case server(Int, String?)
    case tooLarge
    case badReply(String)
    case jobLost
    case jobFailed(String?)
    case doneWithoutMap
    case unknownStatus(String)
    case noTopics
    case tookTooLong
    case missingPlaceholder

    var errorDescription: String? {
        switch self {
        case .server(let status, let body):
            "The server answered with HTTP \(status)." + (body.map { " \($0)" } ?? "")
        case .tooLarge: "This recording is too big for the server."
        case .badReply(let preview): "The server's reply couldn't be read: \(preview)"
        case .jobLost: "The server lost this job. Try again."
        case .jobFailed(let reason): reason ?? "The server couldn't map this recording."
        case .doneWithoutMap: "The server said it was done but sent no map."
        case .unknownStatus(let status): "The server sent an unknown status: \"\(status)\"."
        case .noTopics: "Couldn't find any topics in this recording."
        case .tookTooLong: "This is taking too long. Try again later."
        case .missingPlaceholder: "PlaceholderMap.json isn't in the app bundle."
        }
    }
}
