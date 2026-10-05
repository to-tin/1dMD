import SwiftUI

enum MapStyle {
    static let canvas = Color(hex: 0xFBFAF6)
    static let border = Color(hex: 0xD8D2C0)
    static let ink = Color(hex: 0x0A0A0A)
    static let muted = Color(hex: 0x6B665A)
    static let faintDot = Color(hex: 0xC9C2AE)
    static let ochre = Color(hex: 0xC08A3A)
    static let ochreText = Color(hex: 0xA87425)

    static let card: CGFloat = 184
    static let cornerRadius: CGFloat = 20
    static let columnGap: CGFloat = 112
    static let rowGap: CGFloat = 120
    /// Left strip where "(cont.)" lines run.
    static let laneX: CGFloat = 48
    static let leading: CGFloat = 152
    static let top: CGFloat = 48
    static let margin: CGFloat = 48
    static let bendRadius: CGFloat = 16
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

extension Font {
    /// Bricolage Grotesque once the font file is added to the target; system font until then.
    static func bricolage(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Bricolage Grotesque", size: size).weight(weight)
    }
}

struct NodeMapView: View {
    var data: NodeMapData

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    EdgeLayer(data: data, frame: frame(for:))

                    ForEach(data.edges) { edge in
                        EdgeLabel(edge: edge, data: data, frame: frame(for:))
                    }

                    ForEach(data.nodes) { node in
                        let rect = frame(for: node)
                        NodeCard(node: node, isCurrent: node.id == data.currentID)
                            .id(node.id)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            }
            .onAppear { scrollToCurrent(proxy, animated: false) }
            .onChange(of: data.currentID) { scrollToCurrent(proxy, animated: true) }
        }
        .font(.bricolage(14))
        .monospacedDigit()
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = data.currentID else { return }
        withAnimation(animated ? .easeInOut(duration: 0.4) : nil) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func frame(for node: MapNode) -> CGRect {
        CGRect(
            x: MapStyle.leading + CGFloat(node.column) * (MapStyle.card + MapStyle.columnGap),
            y: MapStyle.top + CGFloat(node.row) * (MapStyle.card + MapStyle.rowGap),
            width: MapStyle.card,
            height: MapStyle.card
        )
    }

    private var contentSize: CGSize {
        let maxRect = data.nodes.map(frame(for:)).reduce(CGRect.zero) { $0.union($1) }
        return CGSize(width: maxRect.maxX + MapStyle.margin, height: maxRect.maxY + MapStyle.margin)
    }
}

// MARK: - Node

private struct NodeCard: View {
    var node: MapNode
    var isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(node.title)
                    .font(.bricolage(17, .semibold))
                if node.isContinuation {
                    Text("(cont.)")
                        .font(.bricolage(17, .medium))
                        .foregroundStyle(MapStyle.ochreText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(height: 24)

            ForEach(node.bullets) { bullet in
                HStack(spacing: 8) {
                    Circle()
                        .fill(bullet.isActive ? MapStyle.ochre : MapStyle.faintDot)
                        .frame(width: 6, height: 6)
                    Text(bullet.text)
                        .foregroundStyle(bullet.isActive ? MapStyle.ink : MapStyle.muted)
                        .lineLimit(1)
                }
                .frame(height: 24)
            }
        }
        .foregroundStyle(MapStyle.ink)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: MapStyle.card, height: MapStyle.card, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: MapStyle.cornerRadius, style: .continuous)
                .fill(.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MapStyle.cornerRadius, style: .continuous)
                .strokeBorder(isCurrent ? MapStyle.ink : MapStyle.border, lineWidth: isCurrent ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if isCurrent {
                Text("NOW")
                    .font(.bricolage(11, .bold))
                    .tracking(0.9)
                    .foregroundStyle(MapStyle.canvas)
                    .frame(width: 48, height: 22)
                    .background(Capsule().fill(MapStyle.ink))
                    .offset(x: -16, y: -11)
            }
        }
    }
}

// MARK: - Edges

private struct EdgeGeometry {
    var path: Path
    var tip: CGPoint
    var angle: Angle
    /// Center of the order/time label (leading edge for `.continued`).
    var label: CGPoint

    static let headLength: CGFloat = 7

    init?(_ edge: MapEdge, data: NodeMapData, frame: (MapNode) -> CGRect) {
        guard let fromNode = data.node(edge.from), let toNode = data.node(edge.to) else { return nil }
        let a = frame(fromNode)
        let b = frame(toNode)
        let r = MapStyle.bendRadius
        let back = Self.headLength / 2
        var p = Path()

        switch edge.kind {
        case .deeper:
            tip = CGPoint(x: b.minX - 1, y: b.midY)
            angle = .zero
            p.move(to: CGPoint(x: a.maxX, y: a.midY))
            p.addLine(to: CGPoint(x: tip.x - back, y: tip.y))
            label = CGPoint(x: (a.maxX + b.minX) / 2, y: a.midY - 20)

        case .newTopic:
            let gapY = b.minY - MapStyle.rowGap / 2
            tip = CGPoint(x: b.midX, y: b.minY - 1)
            angle = .degrees(90)
            p.move(to: CGPoint(x: a.midX, y: a.maxY))
            if abs(a.midX - b.midX) < 1 {
                label = CGPoint(x: a.midX + 44, y: gapY)
            } else {
                p.addArc(tangent1End: CGPoint(x: a.midX, y: gapY), tangent2End: CGPoint(x: b.midX, y: gapY), radius: r)
                p.addArc(tangent1End: CGPoint(x: b.midX, y: gapY), tangent2End: tip, radius: r)
                label = CGPoint(x: (a.midX + b.midX) / 2, y: gapY - 20)
            }
            p.addLine(to: CGPoint(x: tip.x, y: tip.y - back))

        case .continued:
            let lane = MapStyle.laneX
            tip = CGPoint(x: b.minX - 1, y: b.midY)
            angle = .zero
            p.move(to: CGPoint(x: a.minX, y: a.midY))
            p.addArc(tangent1End: CGPoint(x: lane, y: a.midY), tangent2End: CGPoint(x: lane, y: b.midY), radius: r)
            p.addArc(tangent1End: CGPoint(x: lane, y: b.midY), tangent2End: tip, radius: r)
            p.addLine(to: CGPoint(x: tip.x - back, y: tip.y))
            label = CGPoint(x: lane + 12, y: b.midY - 44)
        }
        path = p
    }

    /// Rounded triangle pointing along `angle`, tip at `tip`.
    var head: Path {
        let l = Self.headLength
        var h = Path()
        h.move(to: .zero)
        h.addLine(to: CGPoint(x: -l, y: -l * 0.55))
        h.addLine(to: CGPoint(x: -l, y: l * 0.55))
        h.closeSubpath()
        return h.applying(
            CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: angle.radians)
        )
    }
}

private struct EdgeLayer: View {
    var data: NodeMapData
    var frame: (MapNode) -> CGRect

    var body: some View {
        Canvas { ctx, _ in
            for edge in data.edges {
                guard let g = EdgeGeometry(edge, data: data, frame: frame) else { continue }
                let color: Color
                let style: StrokeStyle
                switch edge.kind {
                case .deeper:
                    color = MapStyle.ink
                    style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0.1, 6])
                case .newTopic:
                    color = MapStyle.ink
                    style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                case .continued:
                    color = MapStyle.ochre
                    style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0.1, 6])
                }
                ctx.stroke(g.path, with: .color(color), style: style)
                ctx.fill(g.head, with: .color(color))
                ctx.stroke(g.head, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

private struct EdgeLabel: View {
    var edge: MapEdge
    var data: NodeMapData
    var frame: (MapNode) -> CGRect

    var body: some View {
        if let g = EdgeGeometry(edge, data: data, frame: frame) {
            if edge.kind == .continued {
                HStack(spacing: 4) {
                    Text("cont.").fontWeight(.semibold)
                    Text(timestamp(edge.time))
                }
                .font(.bricolage(12))
                .foregroundStyle(MapStyle.ochreText)
                .fixedSize()
                .frame(width: 88, alignment: .leading)
                .position(x: g.label.x + 44, y: g.label.y)
            } else {
                HStack(spacing: 4) {
                    if let order = edge.order {
                        Text("\(order).")
                            .fontWeight(.semibold)
                            .foregroundStyle(MapStyle.ink)
                    }
                    Text(timestamp(edge.time))
                        .foregroundStyle(MapStyle.muted)
                }
                .font(.bricolage(12))
                .fixedSize()
                .position(g.label)
            }
        }
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
