import SwiftUI

/// Slides in from the left over the map. Tap outside, or drag the header left, to close.
struct PastChatsDrawer: View {
    @Binding var isOpen: Bool
    var chats: [SavedChat]
    /// The chat on screen, highlighted in the list.
    var currentID: UUID?
    var select: (SavedChat) -> Void
    var delete: (SavedChat) -> Void
    var newChat: () -> Void

    @State private var dragOffset: CGFloat = 0
    @AppStorage(MapService.serverAddressKey) private var serverAddress = ""

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.82, 340)

            ZStack(alignment: .leading) {
                if isOpen {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)

                    panel(width: width)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(MapStyle.node.ignoresSafeArea())
                        .offset(x: min(0, dragOffset))
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: isOpen)
        }
        // While closed, let touches through to the map underneath.
        .allowsHitTesting(isOpen)
    }

    private func panel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Past chats")
                    .font(.title2.bold())
                    .foregroundStyle(MapStyle.ink)
                Spacer()
                Button {
                    newChat()
                    close()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MapStyle.ink)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(MapStyle.button))
                }
                .accessibilityLabel("New chat")
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            // Only the header drags the drawer shut: rows use a left swipe to delete.
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

            if chats.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No chats yet")
                        .font(.body.weight(.medium))
                        .foregroundStyle(MapStyle.ink)
                    Text("Tap the mic to start one, or use + to paste a transcript or import audio.")
                        .font(.footnote)
                        .foregroundStyle(MapStyle.muted)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Spacer()
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(MapStyle.muted)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        ForEach(group.chats) { chat in
                            Button {
                                select(chat)
                                close()
                            } label: {
                                PastChatRow(chat: chat)
                            }
                            .buttonStyle(RowButtonStyle())
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(chat.id == currentID ? MapStyle.button : Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    delete(chat)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Server")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MapStyle.muted)
                TextField("http://127.0.0.1:8000", text: $serverAddress)
                    .font(.footnote.monospaced())
                    .foregroundStyle(MapStyle.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func close() {
        isOpen = false
        dragOffset = 0
    }

    /// Today / Yesterday / Earlier, by when each chat was last updated, newest first.
    private var groups: [(title: String, chats: [SavedChat])] {
        let calendar = Calendar.current
        let sorted = chats.sorted { $0.updated > $1.updated }
        let today = sorted.filter { calendar.isDateInToday($0.updated) }
        let yesterday = sorted.filter { calendar.isDateInYesterday($0.updated) }
        let earlier = sorted.filter { !calendar.isDateInToday($0.updated) && !calendar.isDateInYesterday($0.updated) }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.chats.isEmpty }
    }
}

private struct PastChatRow: View {
    var chat: SavedChat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chat.title ?? "Untitled chat")
                .font(.body.weight(.medium))
                .foregroundStyle(MapStyle.ink)
                .lineLimit(1)

            Text(details)
                .font(.footnote)
                .foregroundStyle(MapStyle.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Date · topics · duration. Pasted and imported chats have no recorded duration.
    private var details: String {
        var parts = [chat.updated.formatted(date: .abbreviated, time: .omitted)]
        if chat.map == nil {
            parts.append("No map yet")
        } else {
            parts.append(chat.topicCount == 1 ? "1 topic" : "\(chat.topicCount) topics")
        }
        if let duration = chat.duration {
            parts.append(duration < 60 ? "<1 min" : "\(Int(duration / 60)) min")
        }
        return parts.joined(separator: " · ")
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
