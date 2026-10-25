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
    /// Space above and below the hairline over an open card's description.
    static let descriptionGap: CGFloat = 10
    static let hairline: CGFloat = 0.5
    /// UIKit twin of `bulletFont`, used to measure how tall a wrapped description is.
    static var bulletUIFont: UIFont { .preferredFont(forTextStyle: .subheadline) }

    static let card: CGFloat = 212
    /// Space between a node and the deeper node below it.
    static let levelGap: CGFloat = 56
    /// Space between topics (room for the dotted new-topic line).
    static let topicGap: CGFloat = 76
    /// How far left of a column a skip-over arrow runs.
    static let skipLane: CGFloat = 14
    /// Top strip where "(cont.)" lines run.
    static let laneY: CGFloat = 40
    static let leading: CGFloat = 32
    static let top: CGFloat = 88
    static let margin: CGFloat = 40
    static let bendRadius: CGFloat = 16
}

extension MapBranch {
    /// Bright set picked for a black screen, so every branch pops.
    /// Used on bullet dots and deeper arrows only; text stays white.
    var color: Color {
        switch self {
        case .purple: Color(hex: 0xD0A2FF)
        case .teal: Color(hex: 0x64FF4F)
        case .blue: Color(hex: 0xFF83B7)
        case .pink: Color(hex: 0xFF3AD9)
        case .green: Color(hex: 0xF9FF7B)
        case .yellow: Color(hex: 0x4784FF)
        case .rose: Color(hex: 0x5800FF)
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

/// Places every node on the canvas. Time moves right: each topic gets its own column,
/// and everything under it stacks down that column like an outline, each sub-topic
/// below everything its earlier sibling led to.
struct MapLayout {
    let frames: [String: CGRect]
    let size: CGSize

    /// `expanded`: ids of cards tapped open, which grow to show their description.
    init(_ data: NodeMapData, expanded: Set<String> = []) {
        var children: [String: [String]] = [:]
        var hasParent = Set<String>()
        for edge in data.edges where edge.kind == .deeper {
            children[edge.from, default: []].append(edge.to)
            hasParent.insert(edge.to)
        }
        let byID = Dictionary(data.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roots = data.nodes
            .filter { $0.isTopic || !hasParent.contains($0.id) }
            .sorted { ($0.line, $0.column) < ($1.line, $1.column) }

        var frames: [String: CGRect] = [:]
        var x = MapStyle.leading
        for root in roots {
            var y = MapStyle.top
            var stack = [root.id]
            while let id = stack.popLast() {
                guard let node = byID[id], frames[id] == nil else { continue }
                let h = Self.height(node, expanded: expanded.contains(id))
                frames[id] = CGRect(x: x, y: y, width: MapStyle.card, height: h)
                y += h + MapStyle.levelGap
                stack.append(contentsOf: (children[id] ?? []).reversed())
            }
            x += MapStyle.card + MapStyle.topicGap
        }
        self.frames = frames
        let bounds = frames.values.reduce(CGRect.zero) { $0.union($1) }
        size = CGSize(width: bounds.maxX + MapStyle.margin, height: bounds.maxY + MapStyle.margin)
    }

    /// Title row plus one row per bullet, with padding top and bottom. An open card with
    /// a description adds a hairline and the wrapped description under the bullets.
    static func height(_ node: MapNode, expanded: Bool = false) -> CGFloat {
        let bullets = CGFloat(node.bullets.count)
        let collapsed = MapStyle.padY * 2 + MapStyle.rowHeight * (1 + bullets) + (bullets > 0 ? MapStyle.titleGap : 0)
        guard expanded, let text = node.shownDescription else { return collapsed }
        return collapsed + MapStyle.descriptionGap * 2 + MapStyle.hairline + descriptionHeight(text)
    }

    /// Width the card's text gets between its side padding.
    static var textWidth: CGFloat { MapStyle.card - MapStyle.padX * 2 }

    /// How tall `text` is once wrapped to the card's text width in the bullet font,
    /// measured by the text system (the same line breaking SwiftUI's Text uses).
    static func descriptionHeight(_ text: String) -> CGFloat {
        // SwiftUI's Text wraps words with the standard line-break strategy (which can push a
        // short last word down a line), so measure with the same rules.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        let box = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: MapStyle.bulletUIFont, .paragraphStyle: paragraph],
            context: nil
        )
        return ceil(box.height)
    }

    /// Centre of the title row.
    static func titleY(in rect: CGRect) -> CGFloat {
        rect.minY + MapStyle.padY + MapStyle.rowHeight / 2
    }

    /// Centre of the bullet row at `index`.
    static func bulletY(_ index: Int, in rect: CGRect) -> CGFloat {
        rect.minY + MapStyle.padY + MapStyle.rowHeight + MapStyle.titleGap + MapStyle.rowHeight * (CGFloat(index) + 0.5)
    }

    /// Whether any node sits between `a` and `b` in the same column.
    func hasNodeBetween(_ a: CGRect, _ b: CGRect) -> Bool {
        frames.values.contains { $0.minX == a.minX && $0.minY > a.minY && $0.minY < b.minY }
    }

    func frame(_ id: String) -> CGRect? { frames[id] }
}

/// The map you can pan and pinch-zoom. While `following`, it glides to keep the
/// current node centred as the conversation moves; touching the map stops that,
/// and the Follow button snaps back to the current node and resumes it.
struct NodeMapView: View {
    var data: NodeMapData
    /// Which chat this map belongs to (nil for the sample or a recording not yet saved).
    /// Open cards close when it changes to another chat.
    var chatID: UUID? = nil

    @State private var following = true
    @State private var recenterToken = 0
    /// Cards tapped open to show their description. Kept by node id, so a card stays open
    /// while the live map updates around it.
    @State private var expanded: Set<String> = []

    var body: some View {
        let layout = MapLayout(data, expanded: expanded)
        let focus = data.currentID.flatMap { layout.frame($0) }.map { CGPoint(x: $0.midX, y: $0.midY) }

        ZoomableMap(
            contentSize: layout.size,
            focusID: data.currentID,
            focus: focus,
            following: $following,
            recenterToken: recenterToken
        ) {
            MapContent(data: data, layout: layout, expanded: expanded, toggle: toggle)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
        // Top right, level with the past chats button (both 16pt in from the map's edges).
        .overlay(alignment: .topTrailing) {
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
        // Any chat change (including to or from the sample, nil): close everything.
        .onChange(of: chatID) { _, _ in
            expanded = []
        }
        // Drop cards that left the map (e.g. the sample replaced by a chat).
        .onChange(of: data.nodes.map(\.id)) { _, ids in
            expanded.formIntersection(ids)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            following = false   // like dragging: don't glide away from a card being read
        }
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
    var expanded: Set<String>
    var toggle: (String) -> Void

    var body: some View {
        let edges = data.edges.compactMap { EdgeGeometry($0, data: data, layout: layout) }

        ZStack(alignment: .topLeading) {
            // Edges are shapes, not a Canvas: a Canvas only paints the part of itself that was on
            // screen at 1x, so zooming out (a UIKit transform SwiftUI can't see) left edges missing.
            ForEach(edges) { $0.shape }

            ForEach(data.nodes) { node in
                if let rect = layout.frame(node.id) {
                    NodeCard(node: node, height: rect.height, isCurrent: node.id == data.currentID,
                             isExpanded: expanded.contains(node.id)) { toggle(node.id) }
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        // The content lives in a UIKit host, so withAnimation from outside doesn't reach it:
        // animate here whenever a card opens or closes.
        .animation(.easeInOut(duration: 0.25), value: expanded)
    }
}

private struct FollowButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                // Same look as the mic: white circle, black icon.
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white))
        }
        .accessibilityLabel("Follow the conversation")
    }
}

// MARK: - Node

/// For VoiceOver, a card with a description is one button: its texts read together and
/// activating it opens or closes the description. Cards without one are left as they are.
private struct DescriptionToggleAccessibility: ViewModifier {
    var hasDescription: Bool
    var isExpanded: Bool
    var toggle: () -> Void

    func body(content: Content) -> some View {
        if hasDescription {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isExpanded ? "Hides the description" : "Shows the description")
                .accessibilityAction { toggle() }
        } else {
            content
        }
    }
}

private struct NodeCard: View {
    var node: MapNode
    var height: CGFloat
    var isCurrent: Bool
    var isExpanded: Bool
    var toggle: () -> Void

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
                if node.shownDescription != nil {
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MapStyle.muted)
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

            if isExpanded, let text = node.shownDescription {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(MapStyle.ring)
                        .frame(height: MapStyle.hairline)
                        .padding(.vertical, MapStyle.descriptionGap)
                    Text(text)
                        .font(MapStyle.bulletFont)
                        .foregroundStyle(MapStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
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
        // While a card grows or shrinks, keep its text inside the rounded shape.
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture { if node.shownDescription != nil { toggle() } }
        .modifier(DescriptionToggleAccessibility(hasDescription: node.shownDescription != nil,
                                                 isExpanded: isExpanded, toggle: toggle))
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

        if edge.kind == .deeper, layout.hasNodeBetween(a, b) {
            // Something sits in the way: leave from the bullet that spawned this branch,
            // run down the left side of the column, and point into the child's title.
            color = target.branch?.color ?? MapStyle.ink
            let index = parent.bullets.firstIndex { $0.branch != nil && $0.branch == target.branch }
            let fromY = index.map { MapLayout.bulletY($0, in: a) } ?? MapLayout.titleY(in: a)
            let lane = a.minX - MapStyle.skipLane
            let toY = MapLayout.titleY(in: b)
            tip = CGPoint(x: b.minX, y: toY)
            angle = .zero
            path = Self.rounded([
                CGPoint(x: a.minX, y: fromY),
                CGPoint(x: lane, y: fromY),
                CGPoint(x: lane, y: toY),
                CGPoint(x: b.minX - Self.headLength + 0.5, y: toY),
            ], radius: 8)
            return
        }

        if edge.kind == .deeper {
            color = target.branch?.color ?? MapStyle.ink
            // Leave from the bottom of the parent, arrive at the top of the child.
            let start = CGPoint(x: a.midX, y: a.maxY)
            tip = CGPoint(x: b.midX, y: b.minY)
            angle = .degrees(90)
            let end = CGPoint(x: tip.x, y: tip.y - Self.headLength + 0.5)
            var p = Path()
            p.move(to: start)
            if abs(start.x - end.x) < 1 {
                p.addLine(to: end)
            } else {
                // Smooth S-curve that ends upright, so the arrow points straight down.
                let midY = (start.y + end.y) / 2
                p.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
            }
            path = p
            return
        }

        var points: [CGPoint]
        let from = MapLayout.titleY(in: a), to = MapLayout.titleY(in: b)
        if edge.kind == .newTopic {
            color = MapStyle.jump
            // Out of the right side, along the gap before the new column, into its title.
            let gapX = b.minX - MapStyle.topicGap / 2
            let start = CGPoint(x: a.maxX, y: from)
            let end = CGPoint(x: b.minX, y: to)
            points = abs(start.y - end.y) < 1
                ? [start, end]
                : [start, CGPoint(x: gapX, y: from), CGPoint(x: gapX, y: to), end]
        } else {
            color = MapStyle.continued
            let lane = MapStyle.laneY
            points = [
                CGPoint(x: a.midX, y: a.minY),
                CGPoint(x: a.midX, y: lane),
                CGPoint(x: b.midX, y: lane),
                CGPoint(x: b.midX, y: b.minY),
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
    private static func rounded(_ points: [CGPoint], radius: CGFloat = MapStyle.bendRadius) -> Path {
        var p = Path()
        p.move(to: points[0])
        for i in 1..<points.count - 1 {
            p.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: radius)
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

    var shape: some View {
        let w = MapStyle.lineWidth
        // Deeper is solid; new-topic and continued lines are round dots.
        let style = kind == .deeper
            ? StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
            : StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: [0.1, w * 3.2])
        return ZStack {
            path.stroke(color, style: style)
            head.fill(color)
            head.stroke(color, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
    }
}

#Preview {
    NodeMapView(data: .sample)
        .background(MapStyle.canvas)
}

extension MapNode {
    /// The description to show, or nil when there's nothing worth a chevron.
    var shownDescription: String? {
        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return description
    }
}

