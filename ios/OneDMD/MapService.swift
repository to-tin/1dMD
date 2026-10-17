import UIKit

/// Uploads one file, then polls the local Python server for a positioned map.
/// The app transcribes the file on the phone first and sends that text along with the audio.
enum MapService {
    static let serverURL = URL(string: "http://127.0.0.1:8000")!

    static var maxWait: Duration {
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "mapMaxWait")
        if override > 0 { return .seconds(override) }
        #endif
        return .seconds(600)
    }

    static var backend: any MapBackend {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "usePlaceholderBackend") { return PlaceholderBackend.shared }
        #endif
        return ServerBackend(base: serverURL)
    }

    static func getResults(
        audioFile: URL,
        transcript: String? = nil,
        using suppliedBackend: (any MapBackend)? = nil,
        waitLimit: Duration? = nil,
        pollInterval: Duration = .seconds(1),
        maxRetries: Int = 5,
        onStage: @escaping @MainActor (MapStage) -> Void = { _ in }
    ) async throws -> NodeMapData {
        let backend = suppliedBackend ?? self.backend
        try Task.checkCancellation()
        await onStage(.uploading)
        // Upload exactly once: retrying a POST could create a duplicate job.
        let accepted = try await keepingAppAwake { try await backend.upload(audioFile, transcript: transcript) }
        try Task.checkCancellation()
        await onStage(.waiting)
        let limit = waitLimit ?? maxWait

        // Race the entire polling phase against a deadline, including retries and in-flight requests.
        return try await withThrowingTaskGroup(of: NodeMapData.self) { group in
            group.addTask {
                try await Task.sleep(for: limit)
                throw MapServiceError.tookTooLong
            }
            group.addTask {
                var delay = pollInterval
                var failures = 0
                while true {
                    try await Task.sleep(for: delay)
                    try Task.checkCancellation()
                    let job: JobStatus
                    do {
                        job = try await backend.status(of: accepted)
                        failures = 0
                    } catch where isTemporary(error) && failures < maxRetries {
                        try Task.checkCancellation()
                        failures += 1
                        delay = min(delay * 2, .seconds(15))
                        continue
                    }
                    try Task.checkCancellation()
                    switch job.status {
                    case "queued", "processing":
                        delay = min(delay + pollInterval, .seconds(5))
                    case "completed":
                        guard let map = job.result else { throw MapServiceError.doneWithoutMap }
                        guard !map.nodes.isEmpty else { throw MapServiceError.noTopics }
                        await onStage(.drawing)
                        try Task.checkCancellation()
                        return map
                    case "failed":
                        throw MapServiceError.jobFailed(job.error)
                    default:
                        throw MapServiceError.unknownStatus(job.status)
                    }
                }
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            try Task.checkCancellation()
            return result
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

struct AcceptedJob: Sendable {
    let id: String
    let statusURL: URL
}

protocol MapBackend: Sendable {
    func upload(_ audio: URL) async throws -> AcceptedJob
    /// Same as `upload(_:)`, plus the on-device transcript. Backends that ignore it can skip this.
    func upload(_ audio: URL, transcript: String?) async throws -> AcceptedJob
    func status(of job: AcceptedJob) async throws -> JobStatus
}

extension MapBackend {
    func upload(_ audio: URL, transcript: String?) async throws -> AcceptedJob {
        try await upload(audio)
    }
}

/// Internal result shared by the HTTP adapter and the explicit debug stand-in.
struct JobStatus: Sendable {
    var status: String
    var result: NodeMapData? = nil
    var error: String? = nil
}

/// What the "Making map…" badge says.
enum MapStage: Equatable {
    case transcribing, uploading, waiting, drawing

    var label: String {
        switch self {
        case .transcribing: "Transcribing…"
        case .uploading: "Uploading…"
        case .waiting: "Waiting for the map…"
        case .drawing: "Making map…"
        }
    }
}

enum MapServiceError: LocalizedError {
    case server(Int, String?)
    case tooLarge
    case unsupportedAudio
    case emptyAudio
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
        case .tooLarge: "Choose an audio file no larger than 25 MiB."
        case .unsupportedAudio: "Choose a WAV, MP3, M4A, AAC, FLAC, OGG, or WebM audio file."
        case .emptyAudio: "The selected audio file is empty."
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
