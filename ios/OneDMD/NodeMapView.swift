import SwiftUI
import UIKit

/// The night look picked in the Style Lab: iOS black, white text, colour only on dots and lines.
enum MapStyle {
    static let canvas = Color.black
    static let node = Color(hex: 0x1C1C1E)
    static let ink = Color.white
    /// Apple's secondary label: bullets that were only mentioned.
    static let muted = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.62)
    static let ring = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.5)
    static let button = Color(hex: 0x2C2C2E)
    /// New-topic jumps: cherry red, dotted.
    static let jump = Color(hex: 0xFF002D)
    /// Back to an earlier topic: sunset orange, dotted.
    static let continued = Color(hex: 0xFF6A1F)

    static let titleFont = Font.headline
    static let bulletFont = Font.subheadline
    static let lineWidth: CGFloat = 1.5
    static let bulletSize: CGFloat = 6
    static let topicRadius: CGFloat = 12
    static let subtopicRadius: CGFloat = 25
    static let padX: CGFloat = 16
    static let padY: CGFloat = 14
    static let rowHeight: CGFloat = 22
    /// Space between the title and the first bullet.
    static let titleGap: CGFloat = 4

    static let card: CGFloat = 212
    static let columnGap: CGFloat = 80
    /// Space between topics (room for the dotted new-topic line).
    static let topicGap: CGFloat = 76
    /// Space between a node and a stacked sibling below it.
    static let stackGap: CGFloat = 24
    /// Left strip where "(cont.)" lines run.
    static let laneX: CGFloat = 40
    static let leading: CGFloat = 88
    static let top: CGFloat = 32
    static let margin: CGFloat = 40
    static let bendRadius: CGFloat = 16
}

extension MapBranch {
    /// "Vivid" set: every colour at the same strength, each at the brightness where it looks best.
    /// Used on bullet dots and deeper arrows only; text stays white.
    var color: Color {
        switch self {
        case .purple: Color(hex: 0xB89FFE)
        case .teal: Color(hex: 0x48E8C5)
        case .blue: Color(hex: 0x7AB4FE)
        case .pink: Color(hex: 0xFF96D3)
        case .green: Color(hex: 0x8BE577)
        case .yellow: Color(hex: 0xF9D544)
        case .rose: Color(hex: 0x48D7FE)
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
        size = CGSize(width: bounds.maxX + MapStyle.margin, height: bounds.maxY + MapStyle.margin)
    }

    /// Title row plus one row per bullet, with padding top and bottom.
    static func height(_ node: MapNode) -> CGFloat {
        let bullets = CGFloat(node.bullets.count)
        return MapStyle.padY * 2 + MapStyle.rowHeight * (1 + bullets) + (bullets > 0 ? MapStyle.titleGap : 0)
    }

    /// Centre of the title row.
    static func titleY(in rect: CGRect) -> CGFloat {
        rect.minY + MapStyle.padY + MapStyle.rowHeight / 2
    }

    /// Centre of the bullet row at `index`.
    static func bulletY(_ index: Int, in rect: CGRect) -> CGFloat {
        rect.minY + MapStyle.padY + MapStyle.rowHeight + MapStyle.titleGap + MapStyle.rowHeight * (CGFloat(index) + 0.5)
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
                .background(Circle().fill(MapStyle.button))
        }
        .accessibilityLabel("Follow the conversation")
    }
}

// MARK: - Node

private struct NodeCard: View {
    var node: MapNode
    var height: CGFloat
    var isCurrent: Bool

    private var radius: CGFloat { node.isTopic ? MapStyle.topicRadius : min(MapStyle.subtopicRadius, height / 2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(node.title)
                    .font(MapStyle.titleFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if node.isContinued {
                    Tag(text: "cont.", foreground: Color(hex: 0x0B0F13), background: MapStyle.continued)
                }
                if isCurrent {
                    Tag(text: "NOW", foreground: .black, background: .white)
                }
            }
            .frame(height: MapStyle.rowHeight)
            .padding(.bottom, node.bullets.isEmpty ? 0 : MapStyle.titleGap)

            ForEach(node.bullets) { bullet in
                HStack(spacing: 9) {
                    BulletDot(bullet: bullet)
                    Text(bullet.text)
                        .font(MapStyle.bulletFont)
                        .foregroundStyle(bullet.isFilled ? MapStyle.ink : MapStyle.muted)
                        .lineLimit(1)
                }
                .frame(height: MapStyle.rowHeight)
            }
        }
        .foregroundStyle(MapStyle.ink)
        .padding(.horizontal, MapStyle.padX)
        .padding(.vertical, MapStyle.padY)
        .frame(width: MapStyle.card, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(MapStyle.node)
        )
        .overlay {
            // Only the current topic gets a border.
            if isCurrent {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2)
            }
        }
    }
}

private struct BulletDot: View {
    var bullet: MapBullet

    var body: some View {
        if bullet.isFilled {
            Circle()
                .fill(bullet.branch?.color ?? MapStyle.ink)
                .frame(width: MapStyle.bulletSize, height: MapStyle.bulletSize)
        } else {
            Circle()
                .strokeBorder(MapStyle.ring, lineWidth: 1.5)
                .frame(width: MapStyle.bulletSize, height: MapStyle.bulletSize)
        }
    }
}

private struct Tag: View {
    var text: String
    var foreground: Color
    var background: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
    }
}

// MARK: - Edges

private struct EdgeGeometry: Identifiable {
    let id: String
    let kind: MapEdgeKind
    let color: Color
    let path: Path
    let tip: CGPoint
    let angle: Angle

    static let headLength: CGFloat = 8.5
    static let headHalfWidth: CGFloat = 4.8

    init?(_ edge: MapEdge, data: NodeMapData, layout: MapLayout) {
        guard let a = layout.frame(edge.from), let b = layout.frame(edge.to),
              let parent = data.node(edge.from), let target = data.node(edge.to) else { return nil }
        id = edge.id
        kind = edge.kind

        if edge.kind == .deeper {
            color = target.branch?.color ?? MapStyle.ink
            // Leave from the bullet that spawned this branch, arrive at the child's title.
            let index = parent.bullets.firstIndex { $0.branch != nil && $0.branch == target.branch }
            let start = CGPoint(x: a.maxX, y: index.map { MapLayout.bulletY($0, in: a) } ?? a.midY)
            tip = CGPoint(x: b.minX, y: MapLayout.titleY(in: b))
            angle = .zero
            let end = CGPoint(x: tip.x - Self.headLength + 0.5, y: tip.y)
            var p = Path()
            p.move(to: start)
            if abs(start.y - end.y) < 1 {
                p.addLine(to: end)
            } else {
                // Smooth S-curve that ends flat, so the arrow points straight in.
                let midX = (start.x + end.x) / 2
                p.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
            }
            path = p
            return
        }

        var points: [CGPoint]
        if edge.kind == .newTopic {
            color = MapStyle.jump
            let gapY = b.minY - MapStyle.topicGap / 2
            let start = CGPoint(x: a.midX, y: a.maxY)
            let end = CGPoint(x: b.midX, y: b.minY)
            points = abs(start.x - end.x) < 1
                ? [start, end]
                : [start, CGPoint(x: start.x, y: gapY), CGPoint(x: end.x, y: gapY), end]
        } else {
            color = MapStyle.continued
            let lane = MapStyle.laneX
            let from = MapLayout.titleY(in: a), to = MapLayout.titleY(in: b)
            points = [
                CGPoint(x: a.minX, y: from),
                CGPoint(x: lane, y: from),
                CGPoint(x: lane, y: to),
                CGPoint(x: b.minX, y: to),
            ]
        }

        tip = points[points.count - 1]
        let before = points[points.count - 2]
        angle = .radians(atan2(tip.y - before.y, tip.x - before.x))
        // Stop the line at the base of the arrowhead.
        let length = max(abs(tip.x - before.x), abs(tip.y - before.y), 1)
        let pull = min(Self.headLength - 0.5, length)
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
        h.addLine(to: CGPoint(x: -l, y: -Self.headHalfWidth))
        h.addLine(to: CGPoint(x: -l, y: Self.headHalfWidth))
        h.closeSubpath()
        return h.applying(CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: angle.radians))
    }

    func draw(in ctx: inout GraphicsContext) {
        let w = MapStyle.lineWidth
        // Deeper is solid; new-topic and continued lines are round dots.
        let style = kind == .deeper
            ? StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
            : StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: [0.1, w * 3.2])
        ctx.stroke(path, with: .color(color), style: style)
        ctx.fill(head, with: .color(color))
        ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }
}

#Preview {
    NodeMapView(data: .sample)
        .background(MapStyle.canvas)
}
