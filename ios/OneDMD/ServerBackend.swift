import Foundation
import UniformTypeIdentifiers

/// Talks to the real server. Used once `MapService.serverURL` is set.
///
/// The addresses and field names below are the app's best guess; READMEBACKEND.md describes
/// them. If the server ends up different, this file is the only one to change.
///
/// Local testing: iOS blocks plain `http://`, so expose a laptop server over https
/// (e.g. `ngrok http 8000`) and use that address.
struct ServerBackend: MapBackend {
    var base: URL

    /// `POST /jobs`, body = the raw audio file → `{ "jobId": "…" }`
    func upload(_ audio: URL) async throws -> String {
        var request = URLRequest(url: base.appending(path: "jobs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(Self.mimeType(of: audio), forHTTPHeaderField: "content-type")
        authorize(&request)

        // Sent straight from the file, so long recordings don't have to fit in memory.
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: audio)
        try Self.check(response, data)
        do {
            return try JSONDecoder().decode(UploadReply.self, from: data).jobId
        } catch {
            throw MapServiceError.badReply(Self.preview(data))
        }
    }

    /// `GET /jobs/{jobId}` → `{ "status": "…", "result": { map JSON }, "error": "…" }`
    func status(of jobId: String) async throws -> JobStatus {
        var request = URLRequest(url: base.appending(path: "jobs").appending(path: jobId))
        request.timeoutInterval = 30
        authorize(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw MapServiceError.jobLost }
        try Self.check(response, data)
        do {
            return try JSONDecoder().decode(JobStatus.self, from: data)
        } catch {
            throw MapServiceError.badReply(Self.preview(data))
        }
    }

    /// Hook for sign-in later. The app never holds an API key; the server keeps its own.
    private func authorize(_ request: inout URLRequest) {}

    private struct UploadReply: Decodable {
        var jobId: String
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        switch status {
        case 200..<300: return
        case 413: throw MapServiceError.tooLarge
        default: throw MapServiceError.server(status, data.isEmpty ? nil : preview(data))
        }
    }

    /// The start of a reply, for error messages, so a mismatch is easy to spot.
    private static func preview(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }

    private static func mimeType(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
