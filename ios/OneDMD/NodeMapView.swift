import SwiftUI
import UIKit

enum MapStyle {
    static let canvas = Color.white
    static let node = Color(hex: 0x111111)
    static let ink = Color(hex: 0x111111)
    static let muted = Color(hex: 0xA3A3A3)
    static let label = Color(hex: 0x6B6B6B)
    static let ring = Color(hex: 0x8A8A8A)
    static let continued = Color(hex: 0xC95D00)

    static let card: CGFloat = 168
    static let columnGap: CGFloat = 80
    /// Space between topics (room for the dotted new-topic line and its time).
    static let topicGap: CGFloat = 72
    /// Space between a node and a stacked sibling below it.
    static let stackGap: CGFloat = 24
    /// Left strip where "(cont.)" lines run.
    static let laneX: CGFloat = 40
    static let leading: CGFloat = 88
    static let top: CGFloat = 32
    static let margin: CGFloat = 40
    static let bendRadius: CGFloat = 16
    /// How far apart arrows leave a node that has more than one child.
    static let splitOffset: CGFloat = 20
}

extension MapBranch {
    /// Arrows and outlines, on the white canvas.
    var line: Color {
        switch self {
        case .purple: Color(hex: 0x8A66D9)
        case .teal: Color(hex: 0x009E8E)
        case .blue: Color(hex: 0x2A80E2)
        case .pink: Color(hex: 0xC34E97)
        case .green: Color(hex: 0x009B44)
        case .yellow: Color(hex: 0xA07C00)
        case .rose: Color(hex: 0xD24B54)
        }
    }

    /// Bullets and text, on the black nodes.
    var tint: Color {
        switch self {
        case .purple: Color(hex: 0xC4ACFF)
        case .teal: Color(hex: 0x37D8C9)
        case .blue: Color(hex: 0x83C1FF)
        case .pink: Color(hex: 0xF99BD1)
        case .green: Color(hex: 0x7CD591)
        case .yellow: Color(hex: 0xD8BD51)
        case .rose: Color(hex: 0xFF9A9B)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Layout

/// Places every node on the canvas. Each line is as tall as its tallest node,
/// and nodes on a line share one centre so straight arrows meet them in the middle.
private struct MapLayout {
    let frames: [String: CGRect]
    let size: CGSize

    init(_ data: NodeMapData) {
        let lines = Dictionary(grouping: data.nodes, by: \.line)
        var centers: [Int: CGFloat] = [:]
        var y = MapStyle.top
        for (index, line) in lines.keys.sorted().enumerated() {
            let nodes = lines[line] ?? []
            let height = nodes.map(Self.height).max() ?? 44
            if index > 0 {
                y += nodes.contains(where: \.isTopic) ? MapStyle.topicGap : MapStyle.stackGap
            }
            centers[line] = y + height / 2
            y += height
        }

        var frames: [String: CGRect] = [:]
        for node in data.nodes {
            let h = Self.height(node)
            frames[node.id] = CGRect(
                x: MapStyle.leading + CGFloat(node.column) * (MapStyle.card + MapStyle.columnGap),
                y: (centers[node.line] ?? 0) - h / 2,
                width: MapStyle.card,
                height: h
            )
        }
        self.frames = frames
        let bounds = frames.values.reduce(CGRect.zero) { $0.union($1) }
        // Extra room at the bottom for a time label under the last line.
        size = CGSize(width: bounds.maxX + MapStyle.margin, height: bounds.maxY + MapStyle.margin)
    }

    /// Title line plus one 20pt line per bullet, with 12pt padding top and bottom.
    static func height(_ node: MapNode) -> CGFloat {
        44 + 20 * CGFloat(node.bullets.count)
    }

    func frame(_ id: String) -> CGRect? { frames[id] }
}

/// The map you can pan and pinch-zoom. While `following`, it glides to keep the
/// current node centred as the conversation moves; touching the map stops that,
/// and the Follow button snaps back to the current node and resumes it.
struct NodeMapView: View {
    var data: NodeMapData

    @State private var following = true
    @State private var recenterToken = 0

    var body: some View {
        let layout = MapLayout(data)
        let focus = data.currentID.flatMap { layout.frame($0) }.map { CGPoint(x: $0.midX, y: $0.midY) }

        ZoomableMap(
            contentSize: layout.size,
            focusID: data.currentID,
            focus: focus,
            following: $following,
            recenterToken: recenterToken
        ) {
            MapContent(data: data, layout: layout)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
        .overlay(alignment: .bottomTrailing) {
            if !following {
                FollowButton {
                    following = true
                    recenterToken += 1
                }
                .padding(16)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: following)
    }
}

/// UIKit's scroll view does the pinch and pan (the same one Photos and Maps use):
/// SwiftUI's own drag and magnify gestures fight each other and pinch often never fires.
private struct ZoomableMap<Content: View>: UIViewRepresentable {
    var contentSize: CGSize
    var focusID: String?
    var focus: CGPoint?
    @Binding var following: Bool
    var recenterToken: Int
    @ViewBuilder var content: () -> Content

    static var minScale: CGFloat { 0.3 }
    static var maxScale: CGFloat { 2 }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MapScrollView {
        let scroll = MapScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = Self.minScale
        scroll.maximumZoomScale = Self.maxScale
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)

        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.didLayout() }
        return scroll
    }

    func updateUIView(_ scroll: MapScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.scroll = scroll
        c.host.rootView = AnyView(content())
        c.applyContentSize()

        if recenterToken != c.lastRecenterToken {
            c.lastRecenterToken = recenterToken
            c.lastFocusID = focusID
            c.centre(zoomToOne: true, animated: true)
        } else if following, focusID != c.lastFocusID {
            let first = c.lastFocusID == nil
            c.lastFocusID = focusID
            c.centre(zoomToOne: false, animated: !first)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableMap
        weak var scroll: MapScrollView?
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        var lastFocusID: String?
        var lastRecenterToken = 0
        private var appliedSize: CGSize = .zero
        private var lastBounds: CGSize = .zero
        private var needsInitialCentre = true
        private var isProgrammatic = false

        init(parent: ZoomableMap) {
            self.parent = parent
            super.init()
            host.sizingOptions = []
            // Inside a scroll view the hosted map must not shift itself for the notch or home bar.
            host.safeAreaRegions = []
        }

        /// Size the content at the current zoom without disturbing the zoom transform.
        func applyContentSize() {
            guard let scroll, parent.contentSize != appliedSize else { return }
            appliedSize = parent.contentSize
            let z = scroll.zoomScale
            host.view.bounds = CGRect(origin: .zero, size: appliedSize)
            host.view.center = CGPoint(x: appliedSize.width * z / 2, y: appliedSize.height * z / 2)
            scroll.contentSize = CGSize(width: appliedSize.width * z, height: appliedSize.height * z)
        }

        func didLayout() {
            guard let scroll, scroll.bounds.size != .zero else { return }
            if scroll.bounds.size != lastBounds {
                lastBounds = scroll.bounds.size
                // Half a screen of slack on every side, so any node can be brought to the centre.
                let w = lastBounds.width / 2, h = lastBounds.height / 2
                scroll.contentInset = UIEdgeInsets(top: h, left: w, bottom: h, right: w)
            }
            if needsInitialCentre {
                needsInitialCentre = false
                centre(zoomToOne: false, animated: false)
            }
        }

        func centre(zoomToOne: Bool, animated: Bool) {
            guard let scroll, let focus = parent.focus, scroll.bounds.size != .zero else {
                needsInitialCentre = true
                return
            }
            let move = {
                self.isProgrammatic = true
                if zoomToOne { scroll.zoomScale = 1 }
                let z = scroll.zoomScale
                scroll.contentOffset = CGPoint(
                    x: focus.x * z - scroll.bounds.width / 2,
                    y: focus.y * z - scroll.bounds.height / 2
                )
                self.isProgrammatic = false
            }
            if animated {
                UIView.animate(withDuration: 0.6, delay: 0, usingSpringWithDamping: 0.9,
                               initialSpringVelocity: 0, options: [.allowUserInteraction], animations: move)
            } else {
                move()
            }
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userMoved() }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            if !isProgrammatic { userMoved() }
        }

        private func userMoved() {
            if parent.following { parent.following = false }
        }
    }
}

final class MapScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

private struct MapContent: View {
    var data: NodeMapData
    var layout: MapLayout

    var body: some View {
        let edges = data.edges.compactMap { EdgeGeometry($0, data: data, layout: layout) }

        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for edge in edges { edge.draw(in: &ctx) }
            }

            // A "(cont.)" link's time is shown on the node's tag instead.
            ForEach(edges.filter { $0.kind != .continued }) { edge in
                Text(timestamp(edge.time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MapStyle.label)
                    .fixedSize()
                    .position(edge.label)
            }

            ForEach(data.nodes) { node in
                if let rect = layout.frame(node.id) {
                    NodeCard(node: node, height: rect.height, isCurrent: node.id == data.currentID)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }
}

private struct FollowButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(MapStyle.ink))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
        .accessibilityLabel("Follow the conversation")
    }
}

// MARK: - Node

private struct NodeCard: View {
    var node: MapNode
    var height: CGFloat
    var isCurrent: Bool

    private var radius: CGFloat { node.isTopic ? 8 : min(28, height / 2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(node.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let at = node.continuedAt {
                    Tag(text: "cont. \(timestamp(at))", foreground: MapStyle.ink, background: MapStyle.continued)
                }
                if isCurrent {
                    Tag(text: "NOW", foreground: MapStyle.ink, background: .white)
                }
            }
            .frame(height: 20)

            ForEach(node.bullets) { bullet in
                HStack(spacing: 8) {
                    BulletDot(bullet: bullet)
                    Text(bullet.text)
                        .font(.system(size: 13))
                        .foregroundStyle(bullet.branch?.tint ?? (bullet.isFilled ? .white : MapStyle.muted))
                        .lineLimit(1)
                }
                .frame(height: 20)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, node.isTopic ? 14 : 20)
        .padding(.vertical, 12)
        .frame(width: MapStyle.card, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(MapStyle.node)
        )
        .overlay {
            if let branch = node.branch {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(branch.line, lineWidth: isCurrent ? 3 : 2)
            }
        }
        .shadow(color: .black.opacity(isCurrent ? 0.18 : 0.12), radius: isCurrent ? 10 : 7, y: isCurrent ? 8 : 4)
    }
}

private struct BulletDot: View {
    var bullet: MapBullet

    var body: some View {
        if bullet.isFilled {
            Circle()
                .fill(bullet.branch?.tint ?? .white)
                .frame(width: 6, height: 6)
        } else {
            Circle()
                .strokeBorder(MapStyle.ring, lineWidth: 1.5)
                .frame(width: 6, height: 6)
        }
    }
}

private struct Tag: View {
    var text: String
    var foreground: Color
    var background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(background))
    }
}

// MARK: - Edges

private struct EdgeGeometry: Identifiable {
    let id: String
    let kind: MapEdgeKind
    let time: TimeInterval
    let color: Color
    let path: Path
    let tip: CGPoint
    let angle: Angle
    /// Centre of the time label.
    let label: CGPoint

    static let headLength: CGFloat = 7

    init?(_ edge: MapEdge, data: NodeMapData, layout: MapLayout) {
        guard let a = layout.frame(edge.from), let b = layout.frame(edge.to),
              let target = data.node(edge.to) else { return nil }
        id = edge.id
        kind = edge.kind
        time = edge.time

        var points: [CGPoint]
        switch edge.kind {
        case .deeper:
            color = target.branch?.line ?? MapStyle.ink
            // Centred, unless the parent has several children: then they fan out above and below.
            let siblings = data.edges.filter { $0.from == edge.from && $0.kind == .deeper }
            let index = siblings.firstIndex { $0.id == edge.id } ?? 0
            let offset = siblings.count > 1
                ? (CGFloat(index) - CGFloat(siblings.count - 1) / 2) * MapStyle.splitOffset
                : 0
            let start = CGPoint(x: a.maxX, y: a.midY + offset)
            let end = CGPoint(x: b.minX - 1, y: b.midY)
            if abs(a.midY - b.midY) < 1 {
                // Same line: straight across, entering at the same height it left.
                points = [start, CGPoint(x: end.x, y: start.y)]
                label = CGPoint(x: (a.maxX + b.minX) / 2, y: start.y - 18)
            } else {
                // Stacked child: step down through the column gap, then in from the left.
                let midX = (a.maxX + b.minX) / 2
                points = [start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end]
                label = CGPoint(x: midX - 30, y: end.y)
            }

        case .newTopic:
            color = MapStyle.ink
            let gapY = b.minY - MapStyle.topicGap / 2
            let start = CGPoint(x: a.midX, y: a.maxY)
            let end = CGPoint(x: b.midX, y: b.minY - 1)
            points = abs(start.x - end.x) < 1
                ? [start, end]
                : [start, CGPoint(x: start.x, y: gapY), CGPoint(x: end.x, y: gapY), end]
            label = CGPoint(x: (start.x + end.x) / 2, y: gapY - 18)

        case .continued:
            color = MapStyle.continued
            let lane = MapStyle.laneX
            points = [
                CGPoint(x: a.minX, y: a.midY),
                CGPoint(x: lane, y: a.midY),
                CGPoint(x: lane, y: b.midY),
                CGPoint(x: b.minX - 1, y: b.midY),
            ]
            label = .zero
        }

        tip = points[points.count - 1]
        let before = points[points.count - 2]
        angle = .radians(atan2(tip.y - before.y, tip.x - before.x))
        // Stop the line under the arrowhead so the round cap doesn't poke past its point.
        let length = max(abs(tip.x - before.x), abs(tip.y - before.y), 1)
        let pull = min(Self.headLength / 2, length)
        points[points.count - 1] = CGPoint(
            x: tip.x - (tip.x - before.x) / length * pull,
            y: tip.y - (tip.y - before.y) / length * pull
        )
        path = Self.rounded(points)
    }

    /// Polyline with rounded bends: no sharp corners anywhere on the map.
    private static func rounded(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: points[0])
        for i in 1..<points.count - 1 {
            p.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: MapStyle.bendRadius)
        }
        p.addLine(to: points[points.count - 1])
        return p
    }

    private var head: Path {
        let l = Self.headLength
        var h = Path()
        h.move(to: .zero)
        h.addLine(to: CGPoint(x: -l, y: -l * 0.55))
        h.addLine(to: CGPoint(x: -l, y: l * 0.55))
        h.closeSubpath()
        return h.applying(CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: angle.radians))
    }

    func draw(in ctx: inout GraphicsContext) {
        let style: StrokeStyle
        switch kind {
        case .deeper:
            style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        case .newTopic, .continued:
            style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0.1, 6])
        }
        ctx.stroke(path, with: .color(color), style: style)
        ctx.fill(head, with: .color(color))
        ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }
}

private func timestamp(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

#Preview {
    NodeMapView(data: .sample)
        .background(MapStyle.canvas)
}
