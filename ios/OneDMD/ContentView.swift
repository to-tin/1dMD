import SwiftUI

enum RecordingState {
    case idle, recording, paused
}

struct ContentView: View {
    @State private var monitor = AudioLevelMonitor()
    @State private var transcriber = AudioTranscriber()
    @State private var state: RecordingState = .idle
    @State private var segmentStart: Date?
    @State private var accumulated: TimeInterval = 0
    /// Placeholder: replays the sample map one move at a time while recording,
    /// until TopicMap feeds real moves in.
    @State private var demoStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Placeholder data until TopicMap is wired in.
            NodeMapView(data: state == .idle ? .sample : NodeMapData.sample.revealed(steps: demoStep))
                .task(id: state) {
                    while state == .recording {
                        try? await Task.sleep(for: .seconds(4))
                        guard state == .recording else { break }
                        withAnimation(.easeOut(duration: 0.3)) { demoStep += 1 }
                    }
                }

            if state != .idle {
                TranscriptLine(final: transcriber.finalText, draft: transcriber.draftText, status: transcriber.status)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
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
        .onAppear {
            // The waveform's mic tap also feeds the transcriber, so the mic is opened once.
            monitor.onBuffer = transcriber.feed.append
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.2)) {
            switch state {
            case .idle:
                monitor.start()
                Task { await transcriber.start() }
                segmentStart = Date()
                accumulated = 0
                demoStep = 0
                state = .recording
            case .recording:
                monitor.pause()
                transcriber.setPaused(true)
                if let segmentStart {
                    accumulated += Date().timeIntervalSince(segmentStart)
                }
                segmentStart = nil
                state = .paused
            case .paused:
                monitor.resume()
                transcriber.setPaused(false)
                segmentStart = Date()
                state = .recording
            }
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) {
            monitor.stop()
            Task { await transcriber.stop() }
            segmentStart = nil
            accumulated = 0
            state = .idle
        }
    }
}

/// The live words: finished phrases in black, words still being heard in grey.
private struct TranscriptLine: View {
    var final: String
    var draft: String
    var status: AudioTranscriber.Status

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(nil, value: draft)
    }

    private var text: AttributedString {
        switch status {
        case .unavailable(let reason):
            return styled(reason, .secondary)
        case .preparing where final.isEmpty && draft.isEmpty:
            return styled("Getting ready…", .secondary)
        case .listening where final.isEmpty && draft.isEmpty:
            return styled("Listening…", .secondary)
        default:
            var out = styled(String(final.suffix(240)), .primary)
            if !draft.isEmpty {
                out += styled(final.isEmpty ? draft : " " + draft, .secondary)
            }
            return out
        }
    }

    private func styled(_ s: String, _ color: Color) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = color
        return a
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

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
