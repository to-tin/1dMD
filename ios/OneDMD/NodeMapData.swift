import Foundation

/// View-side shape of the conversation map. Placeholder until TopicMap is wired in;
/// the real map will be adapted into these types rather than drawn directly.
///
/// Map rules:
/// - A new topic starts a new line (a "row" of the map). Deeper goes right on the same line.
/// - A node's second child stacks on the line below, in the next column.
/// - Going back up inside a topic only moves `currentID`; no node is added.
/// - Returning to a topic from an earlier row adds a "(cont.)" node linked back to the original.
struct MapNode: Identifiable {
    let id: String
    var title: String
    var bullets: [MapBullet]
    /// Vertical slot on the map. A topic starts a new line; stacked children use extra lines.
    var line: Int
    var column: Int
    /// Topics (first node of a row) are rectangles; sub-topics are capsules.
    var isTopic: Bool
    /// Colour of the branch that led here (sub-topics only).
    var branch: MapBranch?
    /// Set on a "(cont.)" node: when the earlier topic was picked back up.
    var continuedAt: TimeInterval?
}

struct MapBullet: Identifiable {
    var text: String
    /// Set when the bullet was talked about in depth and spawned a node of this colour.
    var branch: MapBranch?
    /// Talked about without spawning a sub-topic (e.g. it led to a new topic instead).
    var talkedAbout = false
    var id: String { text }

    /// Filled dot when talked about; hollow ring when only mentioned (an open loop).
    var isFilled: Bool { branch != nil || talkedAbout }
}

/// One colour per branch. All share the same lightness and chroma, so none shouts louder.
enum MapBranch: Int, CaseIterable {
    case purple, teal, blue, pink, green, yellow, rose
}

enum MapEdgeKind {
    /// Same topic, one level deeper. Goes right, solid, in the branch colour.
    case deeper
    /// Unrelated topic. Drops to a new line below, dotted.
    case newTopic
    /// Earlier topic picked back up. Links the original node to its "(cont.)" node.
    case continued
}

struct MapEdge: Identifiable {
    var from: String
    var to: String
    var kind: MapEdgeKind
    /// Seconds into the recording when the move happened.
    var time: TimeInterval
    var id: String { "\(from)>\(to)" }
}

struct NodeMapData {
    var nodes: [MapNode]
    var edges: [MapEdge]
    var currentID: String?

    func node(_ id: String) -> MapNode? {
        nodes.first { $0.id == id }
    }
}

extension NodeMapData {
    /// Dune → Worms → Main character → Timothée, then drifting to New York:
    /// Columbia → My friend, back up to New York, then Pizza.
    static let sample = NodeMapData(
        nodes: [
            MapNode(id: "dune", title: "Dune", bullets: [
                MapBullet(text: "Worms", branch: .purple),
                MapBullet(text: "Spice"),
                MapBullet(text: "Politics"),
            ], line: 0, column: 0, isTopic: true),
            MapNode(id: "worms", title: "Worms", bullets: [
                MapBullet(text: "Main character", branch: .teal),
                MapBullet(text: "Sound design"),
            ], line: 0, column: 1, isTopic: false, branch: .purple),
            MapNode(id: "main", title: "Main character", bullets: [
                MapBullet(text: "Timothée", branch: .blue),
            ], line: 0, column: 2, isTopic: false, branch: .teal),
            MapNode(id: "timothee", title: "Timothée", bullets: [
                MapBullet(text: "Where he's from", talkedAbout: true),
                MapBullet(text: "Other films"),
            ], line: 0, column: 3, isTopic: false, branch: .blue),

            MapNode(id: "nyc", title: "New York", bullets: [
                MapBullet(text: "Columbia", branch: .green),
                MapBullet(text: "Pizza", branch: .yellow),
                MapBullet(text: "Chalamet's hometown"),
            ], line: 1, column: 0, isTopic: true),
            MapNode(id: "columbia", title: "Columbia", bullets: [
                MapBullet(text: "My friend", branch: .rose),
            ], line: 1, column: 1, isTopic: false, branch: .green),
            MapNode(id: "friend", title: "My friend", bullets: [
                MapBullet(text: "Went to Columbia"),
            ], line: 1, column: 2, isTopic: false, branch: .rose),
            MapNode(id: "pizza", title: "Pizza", bullets: [
                MapBullet(text: "I love New York"),
            ], line: 2, column: 1, isTopic: false, branch: .yellow),
        ],
        edges: [
            MapEdge(from: "dune", to: "worms", kind: .deeper, time: 40),
            MapEdge(from: "worms", to: "main", kind: .deeper, time: 85),
            MapEdge(from: "main", to: "timothee", kind: .deeper, time: 130),
            MapEdge(from: "timothee", to: "nyc", kind: .newTopic, time: 185),
            MapEdge(from: "nyc", to: "columbia", kind: .deeper, time: 220),
            MapEdge(from: "columbia", to: "friend", kind: .deeper, time: 255),
            MapEdge(from: "nyc", to: "pizza", kind: .deeper, time: 320),
        ],
        currentID: "pizza"
    )
}
