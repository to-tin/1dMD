import Foundation

/// Turns a pasted transcript into a map: sends the whole text to Claude in one call,
/// gets back a flat list of topics, then lays them out with the same map rules as `NodeMapData`.
enum TranscriptMapper {
    static func map(_ transcript: String) async throws -> NodeMapData {
        let outline = try await requestOutline(for: transcript)
        return NodeMapData(outline, transcript: transcript)
    }

    // MARK: - API call

    private static let model = "claude-opus-5-5"

    private static let instructions = """
    You turn a conversation transcript into a topic map. Read the whole transcript, then list \
    the topics in the order they were talked about.

    - A topic is something the people actually spent time on. Prefer a few solid topics over many \
    tiny ones. Titles are 1–3 words.
    - A node with an empty "parent" is a top-level topic. A node whose "parent" is another node's id \
    is a sub-topic: the conversation went one level deeper into the parent.
    - A sub-topic's title must match one of its parent's bullets exactly.
    - Bullets are the 1–4 things said about a node, 1–4 words each. Set "talkedAbout" to true if the \
    point was actually discussed, false if it was only mentioned and left hanging.
    - If the conversation returns to an earlier top-level topic after other topics, add a new top-level \
    node with the same title and set "continues" to the earlier node's id. Otherwise "continues" is "".
    - "startQuote" is the first 4–6 words of the transcript, copied exactly, where that node begins.
    - Ids are "n1", "n2", … in order. "current" is the id of the node the conversation ended on.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["nodes", "current"],
        "properties": [
            "current": ["type": "string"],
            "nodes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "title", "parent", "continues", "startQuote", "bullets"],
                    "properties": [
                        "id": ["type": "string"],
                        "title": ["type": "string"],
                        "parent": ["type": "string"],
                        "continues": ["type": "string"],
                        "startQuote": ["type": "string"],
                        "bullets": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["text", "talkedAbout"],
                                "properties": [
                                    "text": ["type": "string"],
                                    "talkedAbout": ["type": "boolean"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ]

    private static func requestOutline(for transcript: String) async throws -> TranscriptOutline {
        #if DEBUG
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        #else
        let key = ""
        #endif
        guard !key.isEmpty else { throw MapperError.missingKey }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "system": instructions,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": transcript]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = try JSONDecoder().decode(APIReply.self, from: data)

        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw MapperError.api(reply.error?.message ?? "HTTP \(status)")
        }
        if reply.stopReason == "refusal" { throw MapperError.refused }
        guard let json = reply.content?.last(where: { $0.type == "text" })?.text,
              let jsonData = json.data(using: .utf8) else { throw MapperError.badReply }
        return try JSONDecoder().decode(TranscriptOutline.self, from: jsonData)
    }
}

enum MapperError: LocalizedError {
    case missingKey, refused, badReply
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Set ANTHROPIC_API_KEY in the Xcode Run scheme to map pasted transcripts."
        case .refused: "Claude declined to map this transcript."
        case .badReply: "Claude's reply couldn't be read."
        case .api(let message): message
        }
    }
}

private struct APIReply: Decodable {
    struct Block: Decodable {
        var type: String
        var text: String?
    }
    struct APIError: Decodable {
        var message: String
    }

    var content: [Block]?
    var stopReason: String?
    var error: APIError?

    enum CodingKeys: String, CodingKey {
        case content, error
        case stopReason = "stop_reason"
    }
}

/// The map JSON: topics in the order they came up, linked by `parent`.
/// Used by pasted transcripts and the debug placeholder. Audio uploads use ServerMap.
struct TranscriptOutline: Decodable {
    struct Node: Decodable {
        var id: String
        var title: String
        /// Id of the node this goes deeper into. Missing or "" for a top-level topic.
        var parent: String?
        /// Id of an earlier topic this picks back up. Missing or "" otherwise.
        var continues: String?
        /// Seconds into the audio where this node begins. Preferred over `startQuote`.
        var start: TimeInterval?
        /// First words of the transcript where this node begins, used to estimate `start`.
        var startQuote: String?
        var bullets: [Bullet]?
    }
    struct Bullet: Decodable {
        var text: String
        var talkedAbout: Bool
    }

    var nodes: [Node]
    var current: String
}

// MARK: - Layout

extension NodeMapData {
    /// Applies the map rules to an outline: topics start new lines, deeper goes right,
    /// a second child stacks below, and a returned-to topic gets a "(cont.)" node.
    init(_ outline: TranscriptOutline, transcript: String = "") {
        var nodes: [MapNode] = []
        var edges: [MapEdge] = []
        var position: [String: Int] = [:]
        var childCount: [String: Int] = [:]
        var nextLine = 0
        var nextBranch = 0
        var previousID: String?
        var clock = TranscriptClock(transcript)

        for item in outline.nodes {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, position[item.id] == nil else { continue }
            let time = clock.time(at: item.start, quote: item.startQuote ?? "")

            var seen = Set<String>()
            let bullets = (item.bullets ?? [])
                .filter { !$0.text.isEmpty && seen.insert($0.text.lowercased()).inserted }
                .map { MapBullet(text: $0.text, talkedAbout: $0.talkedAbout) }

            if let parentID = item.parent, let p = position[parentID], parentID != item.id {
                let parent = nodes[p]
                // First child continues the parent's line; any later child stacks on a new line below.
                let line = childCount[parent.id, default: 0] == 0 ? parent.line : nextLine
                childCount[parent.id, default: 0] += 1
                nextLine = max(nextLine, line + 1)

                let branch = MapBranch.allCases[nextBranch % MapBranch.allCases.count]
                nextBranch += 1
                if let b = nodes[p].bullets.firstIndex(where: { $0.text.lowercased() == title.lowercased() }) {
                    nodes[p].bullets[b].branch = branch
                } else {
                    nodes[p].bullets.append(MapBullet(text: title, branch: branch))
                }

                position[item.id] = nodes.count
                nodes.append(MapNode(id: item.id, title: title, bullets: bullets, line: line,
                                     column: parent.column + 1, isTopic: false, branch: branch))
                edges.append(MapEdge(from: parent.id, to: item.id, kind: .deeper, time: time))
            } else {
                let line = nextLine
                nextLine += 1

                let original = item.continues.flatMap { position[$0] }.map { nodes[$0].id }
                position[item.id] = nodes.count
                nodes.append(MapNode(id: item.id, title: title, bullets: bullets, line: line, column: 0,
                                     isTopic: true, continuedAt: original == nil ? nil : time))
                if let previousID, previousID != original {
                    edges.append(MapEdge(from: previousID, to: item.id, kind: .newTopic, time: time))
                }
                if let original {
                    edges.append(MapEdge(from: original, to: item.id, kind: .continued, time: time))
                }
            }
            previousID = item.id
        }

        self.init(
            nodes: nodes,
            edges: edges,
            currentID: position[outline.current] != nil ? outline.current : previousID
        )
    }
}

/// Works out when each node started: from its `start` time if given, otherwise by finding
/// its opening words in the transcript and assuming people talk at about 150 words a minute.
private struct TranscriptClock {
    private let words: [String]
    private var cursor = 0
    private var last: TimeInterval = 0
    private static let wordsPerSecond = 2.5

    init(_ transcript: String) {
        words = transcript.split(whereSeparator: \.isWhitespace).map(Self.normalize)
    }

    /// Uses `seconds` when given; otherwise finds `quote` in the transcript. Never goes backwards.
    mutating func time(at seconds: TimeInterval?, quote: String) -> TimeInterval {
        if let seconds {
            last = max(last, seconds)
            return last
        }
        let target = quote.split(whereSeparator: \.isWhitespace).map(Self.normalize).filter { !$0.isEmpty }.prefix(4)
        if !target.isEmpty, words.count >= target.count {
            for i in cursor...(words.count - target.count)
            where words[i..<(i + target.count)].elementsEqual(target) {
                cursor = i
                last = max(last, Double(i) / Self.wordsPerSecond)
                return last
            }
        }
        return last
    }

    private static func normalize<S: StringProtocol>(_ word: S) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
