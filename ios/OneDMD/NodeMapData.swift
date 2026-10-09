import Foundation

/// View-side shape of the conversation map. Placeholder until TopicMap is wired in;
/// the real map will be adapted into these types rather than drawn directly.
struct MapNode: Identifiable {
    let id: String
    var title: String
    var bullets: [MapBullet]
    var row: Int
    var column: Int
    var isContinuation = false
}

struct MapBullet: Identifiable {
    var text: String
    /// Talked about in depth (spawned its own node). Drawn in ochre.
    var isActive = false
    var id: String { text }
}

enum MapEdgeKind {
    /// Same topic, one level deeper. Goes right, dotted.
    case deeper
    /// Unrelated topic. Starts a new row below, solid.
    case newTopic
    /// Earlier topic picked back up. Links the original node to its "(cont.)" node.
    case continued
}

struct MapEdge: Identifiable {
    var from: String
    var to: String
    var kind: MapEdgeKind
    /// Conversation order (1, 2, 3…). Nil for `.continued`, which marks structure, not a move.
    var order: Int?
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
    static let sample = NodeMapData(
        nodes: [
            MapNode(id: "dune", title: "Dune", bullets: [
                MapBullet(text: "Worm", isActive: true),
                MapBullet(text: "Spice", isActive: true),
                MapBullet(text: "Actors", isActive: true),
                MapBullet(text: "Politics"),
            ], row: 0, column: 0),
            MapNode(id: "worm", title: "Worm scenes", bullets: [
                MapBullet(text: "Ocean", isActive: true),
                MapBullet(text: "Sound design"),
            ], row: 0, column: 1),
            MapNode(id: "ocean", title: "Ocean imagery", bullets: [
                MapBullet(text: "Vastness"),
            ], row: 0, column: 2),

            MapNode(id: "childhood", title: "Childhood", bullets: [
                MapBullet(text: "My brother", isActive: true),
                MapBullet(text: "Sci-fi books"),
            ], row: 1, column: 0),
            MapNode(id: "brother", title: "My brother", bullets: [
                MapBullet(text: "Moving away", isActive: true),
                MapBullet(text: "Road trips"),
            ], row: 1, column: 1),
            MapNode(id: "portland", title: "Portland move", bullets: [
                MapBullet(text: "Rain"),
                MapBullet(text: "Food carts"),
            ], row: 1, column: 2),

            MapNode(id: "portlandia", title: "Portlandia", bullets: [
                MapBullet(text: "Later seasons", isActive: true),
                MapBullet(text: "Sketches"),
            ], row: 2, column: 0),
            MapNode(id: "later", title: "Later seasons", bullets: [
                MapBullet(text: "Cast changes"),
            ], row: 2, column: 1),

            MapNode(id: "dune-cont", title: "Dune", bullets: [
                MapBullet(text: "Spice", isActive: true),
                MapBullet(text: "Actors", isActive: true),
            ], row: 3, column: 0, isContinuation: true),
            MapNode(id: "spice", title: "Spice stuff", bullets: [
                MapBullet(text: "Melange"),
                MapBullet(text: "Fremen"),
            ], row: 3, column: 1),
            MapNode(id: "actors", title: "Actors", bullets: [
                MapBullet(text: "Chalamet"),
                MapBullet(text: "Zendaya"),
            ], row: 3, column: 2),
        ],
        edges: [
            MapEdge(from: "dune", to: "worm", kind: .deeper, order: 1, time: 42),
            MapEdge(from: "worm", to: "ocean", kind: .deeper, order: 2, time: 118),
            MapEdge(from: "ocean", to: "childhood", kind: .newTopic, order: 3, time: 190),
            MapEdge(from: "childhood", to: "brother", kind: .deeper, order: 4, time: 245),
            MapEdge(from: "brother", to: "portland", kind: .deeper, order: 5, time: 331),
            MapEdge(from: "portland", to: "portlandia", kind: .newTopic, order: 6, time: 432),
            MapEdge(from: "portlandia", to: "later", kind: .deeper, order: 7, time: 520),
            MapEdge(from: "later", to: "dune-cont", kind: .newTopic, order: 8, time: 615),
            MapEdge(from: "dune", to: "dune-cont", kind: .continued, order: nil, time: 615),
            MapEdge(from: "dune-cont", to: "spice", kind: .deeper, order: 9, time: 662),
            MapEdge(from: "spice", to: "actors", kind: .deeper, order: 10, time: 746),
        ],
        currentID: "actors"
    )
}
