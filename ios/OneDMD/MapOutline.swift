import Foundation

/// The server's outline behind a map: what the live endpoint reads and returns.
/// Kept with the map (and saved with the chat) so a chat can be continued live.
struct MapOutline: Codable, Sendable, Equatable {
    struct Bullet: Codable, Sendable, Equatable {
        var text: String
        var talkedAbout: Bool
        enum CodingKeys: String, CodingKey { case text, talkedAbout = "talked_about" }
    }

    struct Node: Codable, Sendable, Equatable {
        var id: String
        var title: String
        /// Id of the node this went deeper from; "" for a topic.
        var parent: String
        /// Id of the earlier topic this returns to; "" otherwise.
        var continues: String
        var description: String
        var bullets: [Bullet]
    }

    var nodes: [Node]
    var current: String
}

extension MapOutline {
    /// For maps saved before outlines existed: parents from `deeper` edges, returns from
    /// `continued` edges. Descriptions come from the map's nodes, empty when a node has none.
    init(rebuildingFrom map: NodeMapData) {
        let parents = Dictionary(map.edges.filter { $0.kind == .deeper }.map { ($0.to, $0.from) },
                                 uniquingKeysWith: { first, _ in first })
        let returns = Dictionary(map.edges.filter { $0.kind == .continued }.map { ($0.to, $0.from) },
                                 uniquingKeysWith: { first, _ in first })
        nodes = map.nodes.map { node in
            Node(id: node.id, title: node.title, parent: parents[node.id] ?? "",
                 continues: returns[node.id] ?? "", description: node.description ?? "",
                 bullets: node.bullets.map { Bullet(text: $0.text, talkedAbout: $0.isFilled) })
        }
        current = map.currentID ?? map.nodes.last?.id ?? ""
    }
}
