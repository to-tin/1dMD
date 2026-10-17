import Foundation

/// The map JSON: topics in the order they came up, linked by `parent`.
/// Used by the debug placeholder. Backend responses use ServerMap.
struct TranscriptOutline: Decodable {
    struct Node: Decodable {
        var id: String
        var title: String
        /// Id of the node this goes deeper into. Missing or "" for a top-level topic.
        var parent: String?
        /// Id of an earlier topic this picks back up. Missing or "" otherwise.
        var continues: String?
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
    init(_ outline: TranscriptOutline) {
        var nodes: [MapNode] = []
        var edges: [MapEdge] = []
        var position: [String: Int] = [:]
        var childCount: [String: Int] = [:]
        var nextLine = 0
        var nextBranch = 0
        var previousID: String?

        for item in outline.nodes {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, position[item.id] == nil else { continue }

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
                edges.append(MapEdge(from: parent.id, to: item.id, kind: .deeper))
            } else {
                let line = nextLine
                nextLine += 1

                let original = item.continues.flatMap { position[$0] }.map { nodes[$0].id }
                position[item.id] = nodes.count
                nodes.append(MapNode(id: item.id, title: title, bullets: bullets, line: line, column: 0,
                                     isTopic: true, isContinued: original != nil))
                if let previousID, previousID != original {
                    edges.append(MapEdge(from: previousID, to: item.id, kind: .newTopic))
                }
                if let original {
                    edges.append(MapEdge(from: original, to: item.id, kind: .continued))
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
