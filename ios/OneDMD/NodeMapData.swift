import Foundation

/// View-side shape of the conversation map. Placeholder until TopicMap is wired in;
/// the real map will be adapted into these types rather than drawn directly.
///
/// Map rules:
/// - Time moves right. A new topic starts a new line (a column on screen). Deeper goes down the same line.
/// - A node's second child stacks on the next line (the column to the right), one level down.
/// - Going back up inside a topic only moves `currentID`; no node is added.
/// - Returning to a topic from an earlier row adds a "(cont.)" node linked back to the original.
struct MapNode: Identifiable, Sendable {
    let id: String
    var title: String
    var bullets: [MapBullet]
    /// Left-to-right slot on the map. A topic starts a new line; stacked children use extra lines.
    var line: Int
    /// How deep the node is: 0 for a topic, one more per level. Drawn top to bottom.
    var column: Int
    /// Topics (first node of a row) are rectangles; sub-topics are capsules.
    var isTopic: Bool
    /// Colour of the branch that led here (sub-topics only).
    var branch: MapBranch?
    /// Whether this node picks up an earlier topic.
    var isContinued = false
}

struct MapBullet: Identifiable, Sendable {
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
enum MapBranch: Int, CaseIterable, Sendable {
    case purple, teal, blue, pink, green, yellow, rose
}

enum MapEdgeKind: Sendable {
    /// Same topic, one level deeper. Goes down, solid, in the branch colour.
    case deeper
    /// Unrelated topic. Moves right to a new line, dotted.
    case newTopic
    /// Earlier topic picked back up. Links the original node to its "(cont.)" node.
    case continued
}

struct MapEdge: Identifiable, Sendable {
    var from: String
    var to: String
    var kind: MapEdgeKind
    var id: String { "\(from)>\(to)" }
}

struct NodeMapData: Sendable {
    var nodes: [MapNode]
    var edges: [MapEdge]
    var currentID: String?

    func node(_ id: String) -> MapNode? {
        nodes.first { $0.id == id }
    }

    /// The map as it looked after the first `steps` moves. Used to replay the sample
    /// so the follow-the-conversation behaviour can be seen before the real brain exists.
    func revealed(steps: Int) -> NodeMapData {
        let shown = Array(edges.prefix(max(0, steps)))
        var ids = Set(nodes.prefix(1).map(\.id))
        for edge in shown { ids.insert(edge.from); ids.insert(edge.to) }
        return NodeMapData(
            nodes: nodes.filter { ids.contains($0.id) },
            edges: shown,
            currentID: shown.last?.to ?? nodes.first?.id
        )
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
            MapEdge(from: "dune", to: "worms", kind: .deeper),
            MapEdge(from: "worms", to: "main", kind: .deeper),
            MapEdge(from: "main", to: "timothee", kind: .deeper),
            MapEdge(from: "timothee", to: "nyc", kind: .newTopic),
            MapEdge(from: "nyc", to: "columbia", kind: .deeper),
            MapEdge(from: "columbia", to: "friend", kind: .deeper),
            MapEdge(from: "nyc", to: "pizza", kind: .deeper),
        ],
        currentID: "pizza"
    )
}
