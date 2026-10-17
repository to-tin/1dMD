import Foundation

/// The Python server's transcript/poll contract. See backend/README.md.
struct ServerBackend: MapBackend {
    var base: URL
    var session: URLSession = .shared

    func submit(_ payload: TranscriptRequest) async throws -> AcceptedJob {
        try Task.checkCancellation()
        var request = URLRequest(url: base.appending(path: "jobs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        Self.log(request, response, data)
        try Self.check(response, data, expected: 202)
        try Task.checkCancellation()
        let reply: SubmitReply = try Self.decode(data)
        guard !reply.jobID.isEmpty, reply.status == "queued",
              reply.statusURL.hasPrefix("/jobs/"),
              let url = URL(string: reply.statusURL, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.query == nil, url.fragment == nil else {
            throw MapServiceError.badReply("Invalid job ID or status URL.")
        }
        return AcceptedJob(id: reply.jobID, statusURL: url)
    }

    func status(of job: AcceptedJob) async throws -> JobStatus {
        var request = URLRequest(url: job.statusURL)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        Self.log(request, response, data)
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw MapServiceError.jobLost }
        try Self.check(response, data, expected: 200)
        try Task.checkCancellation()
        let reply: StatusReply = try Self.decode(data)
        guard reply.jobID == job.id else { throw MapServiceError.badReply("The job ID changed.") }
        return JobStatus(status: reply.status, result: try reply.result?.mapData(), error: reply.error)
    }

    private struct SubmitReply: Decodable {
        var jobID: String
        var status: String
        var statusURL: String
        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", status, statusURL = "status_url"
        }
    }

    private struct StatusReply: Decodable {
        var jobID: String
        var status: String
        var result: ServerMap?
        var error: String?
        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", status, result, error
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MapServiceError.badReply(String(decoding: data.prefix(200), as: UTF8.self)) }
    }

    private static func check(_ response: URLResponse, _ data: Data, expected: Int) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw MapServiceError.badReply("Expected an HTTP response.")
        }
        if status == expected { return }
        if status == 413 { throw MapServiceError.tooLarge }
        throw MapServiceError.server(status, String(decoding: data.prefix(200), as: UTF8.self))
    }

    private static func log(_ request: URLRequest, _ response: URLResponse, _ data: Data) {
        #if DEBUG
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[1DMD] \(request.httpMethod ?? "GET") \(request.url?.path ?? "") → \(code)\n\(String(decoding: data, as: UTF8.self))")
        #endif
    }
}
