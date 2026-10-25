import UIKit

/// Submits a transcript, then polls the local Python server for a positioned map.
enum MapService {
    static let serverAddressKey = "serverURL"
    static let defaultServerURL = URL(string: "http://127.0.0.1:8000")!

    /// The simulator reaches the Mac at 127.0.0.1; a real iPhone needs the Mac's Wi-Fi
    /// address, set under Past chats → Server.
    static var serverURL: URL {
        parse(UserDefaults.standard.string(forKey: serverAddressKey) ?? "") ?? defaultServerURL
    }

    /// The typed address as a URL ("192.168.1.20:8000" gets http://), or nil if it isn't one.
    /// Typed without http:// or a port, it gets the server's port 8000 rather than http's 80.
    static func parse(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = !text.isEmpty && !text.contains("://")
        if bare { text = "http://" + text }
        guard var components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme), let host = components.host,
              // A name with no dot ("macbook", or "http" from "http:/…") can't be the Mac.
              host.contains(".") || host.contains(":") || host == "localhost",
              !host.contains(" ") else { return nil }
        if bare, components.port == nil { components.port = 8000 }
        guard let url = components.url else { return nil }
        if let port = url.port, !(1...65535).contains(port) { return nil }
        return url
    }

    static var maxWait: Duration {
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "mapMaxWait")
        if override > 0 { return .seconds(override) }
        #endif
        return .seconds(600)
    }

    static var liveBackend: any LiveBackend {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "usePlaceholderBackend") { return PlaceholderBackend.shared }
        #endif
        return CurrentServer()
    }

    /// Reads the server address on every request, so fixing it mid-recording takes effect
    /// on the next update.
    private struct CurrentServer: LiveBackend {
        func update(_ request: LiveRequest) async throws -> LiveReply {
            try await ServerBackend(base: MapService.serverURL).update(request)
        }
    }

    static var backend: any MapBackend {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "usePlaceholderBackend") { return PlaceholderBackend.shared }
        #endif
        return ServerBackend(base: serverURL)
    }

    static func getResults(
        transcript: String,
        using suppliedBackend: (any MapBackend)? = nil,
        waitLimit: Duration? = nil,
        pollInterval: Duration = .seconds(1),
        maxRetries: Int = 5,
        onStage: @escaping @MainActor (MapStage) -> Void = { _ in }
    ) async throws -> NodeMapData {
        let backend = suppliedBackend ?? self.backend
        try Task.checkCancellation()
        await onStage(.uploading)
        // Submit exactly once: retrying a POST could create a duplicate job.
        let accepted = try await keepingAppAwake { try await backend.submit(TranscriptRequest(transcript: transcript)) }
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
    /// LiveMapper uses the same rule to decide which failed batches to retry.
    static func isTemporary(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        if case .server(let status, _) = error as? MapServiceError {
            return [429, 502, 503, 504].contains(status)
        }
        return false
    }

    /// The server as people type it: "192.168.1.20:8000".
    static func address(of server: URL) -> String {
        var host = server.host ?? server.absoluteString
        if host.contains(":") { host = "[\(host)]" }     // IPv6 needs its brackets
        return server.port.map { "\(host):\($0)" } ?? host
    }

    /// A plain-language reason the phone couldn't use the server, for the screen.
    static func explain(_ error: Error, server: URL = serverURL) -> String {
        let address = address(of: server)
        #if !targetEnvironment(simulator)
        let host = server.host ?? ""
        if host == "localhost" || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.") {
            return "\(address) isn't your Mac's address. Set Server to the one the Mac prints when the server starts, like 192.168.1.20:8000."
        }
        #endif
        if let error = error as? URLError {
            // iOS reports a denied Local Network permission as "no internet", with this in the path.
            if String(describing: error).contains("Local network prohibited") {
                return "iOS is blocking local network access. Tap Allow if iOS asks, or turn on Settings → Privacy & Security → Local Network → 1dMD."
            }
            switch error.code {
            case .cannotConnectToHost:
                return "Nothing is answering at \(address). Check the server is running (./1dmd start --host 0.0.0.0) and the port matches."
            case .timedOut, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
                return "No answer from \(address). Check the phone is on the same Wi-Fi as the Mac and the address is right. Guest Wi-Fi or a VPN can also block it."
            case .notConnectedToInternet:
                return "The phone can't reach the network. Check Wi-Fi is on, and Settings → Privacy & Security → Local Network → 1dMD."
            case .appTransportSecurityRequiresSecureConnection:
                return "iOS blocked plain http to \(address). The app's network settings (Info.plist) need an exception for it."
            default:
                return "Can't reach \(address): \(error.localizedDescription)"
            }
        }
        if case .server(let status, _) = error as? MapServiceError {
            return "The server at \(address) had a problem (\(status))."
        }
        return "Can't use the server at \(address): \(error.localizedDescription)"
    }

    /// Asks the server's /health. Returns nil when it answered, else what went wrong.
    static func check(_ server: URL = serverURL, session: URLSession = .shared) async -> String? {
        var request = URLRequest(url: server.appending(path: "health"))
        request.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return "\(address(of: server)) answered, but it isn't the 1DMD server."
            }
            return nil
        } catch {
            return explain(error, server: server)
        }
    }

    /// Asks iOS for extra time so a submission isn't cut off if the user leaves the app.
    @MainActor
    private static func keepingAppAwake<T>(_ work: () async throws -> T) async rethrows -> T {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "Submit transcript") {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        defer { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
        return try await work()
    }
}

// MARK: - Types

struct LiveRequest: Encodable, Sendable {
    var outline: MapOutline?
    var previousWords: String
    var words: String
    enum CodingKeys: String, CodingKey { case outline, previousWords = "previous_words", words }

    // Always send "outline" (as null on a chat's first call), matching the server contract.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outline, forKey: .outline)
        try c.encode(previousWords, forKey: .previousWords)
        try c.encode(words, forKey: .words)
    }
}

struct LiveReply: Sendable {
    /// nil only when the server has nothing to draw yet (no API key, first call).
    var map: NodeMapData?
    var move: String
}

protocol LiveBackend: Sendable {
    func update(_ request: LiveRequest) async throws -> LiveReply
}

struct AcceptedJob: Sendable {
    let id: String
    let statusURL: URL
}

struct TranscriptRequest: Encodable, Sendable {
    let transcript: String
}

protocol MapBackend: Sendable {
    func submit(_ payload: TranscriptRequest) async throws -> AcceptedJob
    func status(of job: AcceptedJob) async throws -> JobStatus
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
        case .transcribing: "Transcribing audio…"
        case .uploading: "Sending transcript…"
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
        case .jobFailed(let reason): reason ?? "The server couldn't map this transcript."
        case .doneWithoutMap: "The server said it was done but sent no map."
        case .unknownStatus(let status): "The server sent an unknown status: \"\(status)\"."
        case .noTopics: "Couldn't find any topics in this transcript."
        case .tookTooLong: "This is taking too long. Try again later."
        case .missingPlaceholder: "PlaceholderMap.json isn't in the app bundle."
        }
    }
}
