import SwiftUI

/// A past conversation, as shown in the drawer. UI only for now: nothing is saved yet,
/// so the drawer shows `samples`.
struct PastChat: Identifiable {
    let id = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval
    var topicCount: Int

    static let samples: [PastChat] = {
        let now = Date()
        func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [
            PastChat(title: "Weekend trip plans", date: ago(hours: 2), duration: 14 * 60, topicCount: 5),
            PastChat(title: "Startup pitch feedback", date: ago(hours: 6), duration: 32 * 60, topicCount: 9),
            PastChat(title: "Dinner with Sam", date: ago(hours: 28), duration: 51 * 60, topicCount: 12),
            PastChat(title: "Lease renewal", date: ago(hours: 30), duration: 8 * 60, topicCount: 3),
            PastChat(title: "Book club: Dune", date: ago(hours: 24 * 5), duration: 64 * 60, topicCount: 14),
            PastChat(title: "Team standup", date: ago(hours: 24 * 9), duration: 12 * 60, topicCount: 4),
        ]
    }()
}

/// Slides in from the left over the map. Tap outside or drag left to close.
struct PastChatsDrawer: View {
    @Binding var isOpen: Bool
    var chats: [PastChat] = PastChat.samples
    var select: (PastChat) -> Void = { _ in }

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.82, 340)

            ZStack(alignment: .leading) {
                if isOpen {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)

                    panel
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(MapStyle.node.ignoresSafeArea())
                        .offset(x: min(0, dragOffset))
                        .gesture(
                            DragGesture()
                                .onChanged { dragOffset = $0.translation.width }
                                .onEnded { value in
                                    if value.translation.width < -width / 3 || value.predictedEndTranslation.width < -width {
                                        close()
                                    } else {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                                    }
                                }
                        )
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: isOpen)
        }
        // While closed, let touches through to the map underneath.
        .allowsHitTesting(isOpen)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Past chats")
                .font(.title2.bold())
                .foregroundStyle(MapStyle.ink)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MapStyle.muted)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 4)

                        ForEach(group.chats) { chat in
                            Button {
                                select(chat)
                                close()
                            } label: {
                                PastChatRow(chat: chat)
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func close() {
        isOpen = false
        dragOffset = 0
    }

    /// Today / Yesterday / Earlier, newest first.
    private var groups: [(title: String, chats: [PastChat])] {
        let calendar = Calendar.current
        let sorted = chats.sorted { $0.date > $1.date }
        let today = sorted.filter { calendar.isDateInToday($0.date) }
        let yesterday = sorted.filter { calendar.isDateInYesterday($0.date) }
        let earlier = sorted.filter { !calendar.isDateInToday($0.date) && !calendar.isDateInYesterday($0.date) }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.chats.isEmpty }
    }
}

private struct PastChatRow: View {
    var chat: PastChat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chat.title)
                .font(.body.weight(.medium))
                .foregroundStyle(MapStyle.ink)
                .lineLimit(1)

            Text("\(chat.date.formatted(date: .abbreviated, time: .omitted)) · \(chat.topicCount) topics · \(Int(chat.duration / 60)) min")
                .font(.footnote)
                .foregroundStyle(MapStyle.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? MapStyle.button : Color.clear)
    }
}

/// Opens the drawer. Same look as the mic: white circle, black icon.
struct PastChatsButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuLines()
                .fill(.black)
                .frame(width: 18, height: 14)
                // The short bottom line leaves the upper left heavier,
                // so nudge it down-right to sit centred to the eye.
                .offset(x: 2.0 / 3, y: 2.0 / 3)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white))
        }
        .accessibilityLabel("Past chats")
    }
}

/// Three rounded lines, the bottom one half length. 2pt lines on a 6pt rhythm,
/// so every edge lands on a whole pixel at 2x and 3x.
private struct MenuLines: Shape {
    func path(in rect: CGRect) -> Path {
        let thickness: CGFloat = 2
        let step = (rect.height - thickness) / 2
        var path = Path()
        for (row, length) in [1.0, 1.0, 0.5].enumerated() {
            let line = CGRect(x: rect.minX, y: rect.minY + CGFloat(row) * step,
                              width: rect.width * length, height: thickness)
            path.addRoundedRect(in: line, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}
