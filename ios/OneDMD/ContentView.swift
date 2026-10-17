import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingAudioPicker = false
    /// What the running upload is doing; nil when nothing is running.
    @State private var stage: MapStage?
    @State private var mappingTask: Task<Void, Never>?
    /// Identifies the latest job, so an older one finishing late can't overwrite it.
    @State private var currentJob: UUID?
    @State private var mapError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Sample data until audio is uploaded, a transcript is pasted, or TopicMap is wired in.
            NodeMapView(data: mapData)
                .overlay(alignment: .topTrailing) {
                    AddMenu(
                        uploadAudio: { showingAudioPicker = true },
                        pasteTranscript: { showingPaste = true }
                    )
                    .disabled(stage != nil)
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                }
                .overlay {
                    if let stage {
                        MappingBadge(stage: stage, cancel: cancelMap)
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
            PasteTranscriptView { transcript in
                makeMap(startingAt: .drawing) { try await TranscriptMapper.map(transcript) }
            }
        }
        .fileImporter(isPresented: $showingAudioPicker, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): mapAudio(url)
            case .failure(let error): mapError = error.localizedDescription
            }
        }
        .alert("Couldn't make the map", isPresented: Binding(get: { mapError != nil }, set: { if !$0 { mapError = nil } })) {
            Button("OK") { mapError = nil }
        } message: {
            Text(mapError ?? "")
        }
    }

    /// Copies the picked file into the app first: picked files are only readable while the
    /// picker grants access, and the upload happens after that. Each copy gets its own folder,
    /// deleted once the job ends.
    private func mapAudio(_ picked: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let copy = folder.appending(path: picked.lastPathComponent)
        do {
            let access = picked.startAccessingSecurityScopedResource()
            defer { if access { picked.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picked, to: copy)
        } catch {
            mapError = error.localizedDescription
            return
        }
        makeMap(startingAt: .uploading) {
            defer { try? FileManager.default.removeItem(at: folder) }
            return try await MapService.getResults(audioFile: copy) { stage = $0 }
        }
    }

    private func makeMap(startingAt first: MapStage, _ work: @escaping () async throws -> NodeMapData) {
        mappingTask?.cancel()
        let job = UUID()
        currentJob = job
        stage = first
        mappingTask = Task {
            do {
                let data = try await work()
                if currentJob == job {
                    withAnimation(.easeOut(duration: 0.3)) { mapData = data }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if currentJob == job { mapError = error.localizedDescription }
            }
            if currentJob == job {
                stage = nil
                mappingTask = nil
            }
        }
    }

    /// Stops the running job and keeps the map that was already showing.
    private func cancelMap() {
        mappingTask?.cancel()
        mappingTask = nil
        currentJob = nil
        stage = nil
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

private struct AddMenu: View {
    var uploadAudio: () -> Void
    var pasteTranscript: () -> Void

    var body: some View {
        Menu {
            Button("Upload audio", systemImage: "waveform", action: uploadAudio)
            Button("Paste transcript", systemImage: "doc.on.clipboard", action: pasteTranscript)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        }
        .accessibilityLabel("Add a conversation")
    }
}

private struct MappingBadge: View {
    var stage: MapStage
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(stage.label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.2)))
            }
            .accessibilityLabel("Cancel")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
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
