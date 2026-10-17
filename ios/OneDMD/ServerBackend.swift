import Foundation
import UniformTypeIdentifiers

/// The Python server's upload/poll contract. See backend/README.md.
struct ServerBackend: MapBackend {
    var base: URL
    var session: URLSession = .shared

    func upload(_ audio: URL) async throws -> AcceptedJob {
        try await upload(audio, transcript: nil)
    }

    func upload(_ audio: URL, transcript: String?) async throws -> AcceptedJob {
        let body = try MultipartAudio.create(from: audio, transcript: transcript)
        defer { try? FileManager.default.removeItem(at: body.url) }
        try Task.checkCancellation()
        var request = URLRequest(url: base.appending(path: "jobs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: body.url)
        Self.log(request, response, data)
        try Self.check(response, data, expected: 202)
        try Task.checkCancellation()
        let reply: UploadReply = try Self.decode(data)
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

    private struct UploadReply: Decodable {
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

/// A disk-backed multipart body; audio is copied in bounded chunks, never loaded all at once.
struct MultipartAudio {
    let url: URL
    let boundary: String
    static let maxBytes = 25 * 1024 * 1024
    static let extensions: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "webm"]

    /// `transcript`, when given, is sent as a plain text field named `transcript` before the audio.
    static func create(from audio: URL, transcript: String? = nil) throws -> MultipartAudio {
        let ext = audio.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw MapServiceError.unsupportedAudio }
        let boundary = "1dmd-\(UUID().uuidString)"
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(boundary).multipart")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: audio)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            if let transcript {
                let field = "--\(boundary)\r\nContent-Disposition: form-data; name=\"transcript\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(transcript)\r\n"
                try output.write(contentsOf: Data(field.utf8))
            }
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            // A fixed filename avoids injecting quotes or newlines from a picked filename.
            let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            var size = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                size += chunk.count
                guard size <= maxBytes else { throw MapServiceError.tooLarge }
                try output.write(contentsOf: chunk)
            }
            guard size > 0 else { throw MapServiceError.emptyAudio }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return MultipartAudio(url: destination, boundary: boundary)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
