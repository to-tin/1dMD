import SwiftUI

enum RecordingState {
    case idle, recording, paused
}

struct ContentView: View {
    @State private var monitor = AudioLevelMonitor()
    @State private var state: RecordingState = .idle
    @State private var segmentStart: Date?
    @State private var accumulated: TimeInterval = 0
    @State private var mapData: NodeMapData = .sample
    @State private var showingPaste = false
    @State private var isMapping = false
    @State private var mapError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Sample data until a transcript is pasted or TopicMap is wired in.
            NodeMapView(data: mapData)
                .overlay(alignment: .topTrailing) {
                    AddButton { showingPaste = true }
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                }
                .overlay {
                    if isMapping {
                        MappingBadge()
                    }
                }

            HStack(spacing: 12) {
                if state != .idle {
                    TimerLabel(segmentStart: segmentStart, accumulated: accumulated)
                }

                WaveformView(samples: monitor.samples)
                    .frame(height: 48)

                MicButton(state: state) {
                    toggle()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(MapStyle.canvas.ignoresSafeArea())
        .sheet(isPresented: $showingPaste) {
            PasteTranscriptView { mapTranscript($0) }
        }
        .alert("Couldn't map transcript", isPresented: Binding(get: { mapError != nil }, set: { if !$0 { mapError = nil } })) {
            Button("OK") { mapError = nil }
        } message: {
            Text(mapError ?? "")
        }
    }

    private func mapTranscript(_ transcript: String) {
        isMapping = true
        Task {
            do {
                let data = try await TranscriptMapper.map(transcript)
                withAnimation(.easeOut(duration: 0.3)) { mapData = data }
            } catch {
                mapError = error.localizedDescription
            }
            isMapping = false
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.2)) {
            switch state {
            case .idle:
                monitor.start()
                segmentStart = Date()
                accumulated = 0
                state = .recording
            case .recording:
                monitor.pause()
                if let segmentStart {
                    accumulated += Date().timeIntervalSince(segmentStart)
                }
                segmentStart = nil
                state = .paused
            case .paused:
                monitor.resume()
                segmentStart = Date()
                state = .recording
            }
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) {
            monitor.stop()
            segmentStart = nil
            accumulated = 0
            state = .idle
        }
    }
}

private struct TimerLabel: View {
    var segmentStart: Date?
    var accumulated: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = segmentStart.map { context.date.timeIntervalSince($0) } ?? 0
            Text(formatted(elapsed: accumulated + live))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func formatted(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct DoneButton: View {
    var elapsed: TimeInterval
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.black)
                .clipShape(Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct MicButton: View {
    var state: RecordingState
    var action: () -> Void

    private var icon: String {
        switch state {
        case .idle: return "mic.fill"
        case .recording: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)

                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct AddButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("Paste transcript")
    }
}

private struct MappingBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Mapping transcript…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Capsule().fill(Color.black))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
