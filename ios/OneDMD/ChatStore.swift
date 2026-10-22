import Foundation

/// One saved conversation: the words and the map made from them.
/// Continuing a chat adds to the same record, so it's never duplicated.
struct SavedChat: Identifiable, Sendable, Codable {
    /// Bumped if the file shape ever changes, so old files can still be read.
    var version = 1
    let id: UUID
    /// The first topic's name; nil until a map has been made.
    var title: String?
    /// When the chat started.
    let date: Date
    /// When it was last saved or continued. The drawer sorts by this.
    var updated: Date
    /// Total recorded seconds across every session; nil for pasted or imported chats.
    var duration: TimeInterval?
    /// Everything said so far. Kept so a continued chat can be re-mapped as a whole.
    var transcript: String
    /// Nil while the first map is still being made, or if making it failed.
    var map: NodeMapData?

    init(transcript: String, duration: TimeInterval? = nil, map: NodeMapData? = nil, now: Date = .now) {
        id = UUID()
        date = now
        updated = now
        self.transcript = transcript
        self.duration = duration
        self.map = nil
        if let map { setMap(map) }
    }

    var topicCount: Int { map?.topics.count ?? 0 }

    /// Stores a new map and names the chat after its first topic, unless it already has a name.
    mutating func setMap(_ map: NodeMapData) {
        self.map = map
        if title == nil { title = map.topics.first?.title }
    }

    /// Adds newly recorded words to the end of the transcript.
    mutating func append(words: String, recorded seconds: TimeInterval, now: Date = .now) {
        transcript = transcript.isEmpty ? words : transcript + "\n\n" + words
        duration = (duration ?? 0) + seconds
        updated = now
    }
}

/// Keeps chats on the phone as one JSON file each, in the app's Documents folder
/// (which iOS includes in the phone's iCloud or computer backup).
/// One file per chat means a bad write can only ever touch that one chat.
struct ChatStore {
    let folder: URL

    init(folder: URL = URL.documentsDirectory.appending(path: "chats", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    /// Every readable chat, most recently updated first. A file that can't be read is
    /// skipped and left on disk, never deleted.
    func all() -> [SavedChat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(SavedChat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    /// Writes the whole file at once, so a crash leaves either the old file or the new one.
    func save(_ chat: SavedChat) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(chat).write(to: file(for: chat.id), options: .atomic)
    }

    func delete(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: file(for: id))
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }

    private func file(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
