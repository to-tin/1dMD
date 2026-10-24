import Foundation

/// Wire DTO for the Python processor's positioned graph, independent of pasted transcripts.
struct ServerMap: Decodable {
    struct Node: Decodable {
        var id: String
        var title: String
        var isTopic: Bool
        var line: Int
        var column: Int
        var bullets: [Bullet]
        var branch: String?
    }
    struct Bullet: Decodable {
        var text: String
        var branch: String?
        var talkedAbout: Bool?
    }
    struct Edge: Decodable {
        var from: String
        var to: String
        var kind: String
    }
    var currentID: String?
    var outline: MapOutline?
    var nodes: [Node]
    var edges: [Edge]

    func mapData() throws -> NodeMapData {
        guard !nodes.isEmpty else { throw MapServiceError.noTopics }
        let ids = Set(nodes.map(\.id))
        guard ids.count == nodes.count, !ids.contains(""),
              currentID.map({ ids.contains($0) }) ?? true else {
            throw MapServiceError.badReply("Invalid or duplicate node IDs.")
        }
        let continuedIDs = Set(edges.filter { $0.kind == "continued" }.map(\.to))
        let mappedNodes = try nodes.map { node in
            guard node.line >= 0, node.column >= 0,
                  !node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MapServiceError.badReply("Invalid node layout or title.")
            }
            return MapNode(
                id: node.id, title: node.title,
                bullets: try node.bullets.map {
                    MapBullet(text: $0.text, branch: try Self.branch($0.branch), talkedAbout: $0.talkedAbout ?? false)
                },
                line: node.line, column: node.column, isTopic: node.isTopic,
                branch: try Self.branch(node.branch), isContinued: continuedIDs.contains(node.id)
            )
        }
        var edgeIDs = Set<String>()
        let mappedEdges = try edges.map { edge in
            guard ids.contains(edge.from), ids.contains(edge.to),
                  edgeIDs.insert("\(edge.from)>\(edge.to)").inserted else {
                throw MapServiceError.badReply("Invalid or duplicate edge references.")
            }
            let kind: MapEdgeKind
            switch edge.kind {
            case "deeper": kind = .deeper
            case "newTopic": kind = .newTopic
            case "continued": kind = .continued
            default: throw MapServiceError.badReply("Unknown edge kind: \(edge.kind)")
            }
            return MapEdge(from: edge.from, to: edge.to, kind: kind)
        }
        var map = NodeMapData(nodes: mappedNodes, edges: mappedEdges, currentID: currentID)
        map.outline = outline
        return map
    }

    private static func branch(_ name: String?) throws -> MapBranch? {
        switch name {
        case nil: return nil
        case "purple": return .purple
        case "teal": return .teal
        case "blue": return .blue
        case "pink": return .pink
        case "green": return .green
        case "yellow": return .yellow
        case "rose": return .rose
        default: throw MapServiceError.badReply("Unknown branch color: \(name!)")
        }
    }
}
