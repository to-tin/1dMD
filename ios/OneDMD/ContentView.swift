import SwiftUI
import UniformTypeIdentifiers

enum RecordingState {
    case idle, recording, paused
}

struct ContentView: View {
    @State private var monitor = AudioLevelMonitor()
    @State private var transcriber = AudioTranscriber()
    @State private var state: RecordingState = .idle
    @State private var segmentStart: Date?
    @State private var accumulated: TimeInterval = 0
    @State private var mapData: NodeMapData = .sample
    @State private var showingPaste = false
    @State private var showingAudioPicker = false
    /// What the running mapping operation is doing; nil when nothing is running.
    @State private var stage: MapStage?
    @State private var mappingTask: Task<Void, Never>?
    /// Identifies the latest job, so an older one finishing late can't overwrite it.
    @State private var currentJob: UUID?
    @State private var mapError: String?
    /// Placeholder: replays the sample map one move at a time while recording,
    /// until TopicMap feeds real moves in.
    @State private var demoStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // When idle: the sample, or the map from an imported audio file or pasted transcript.
            // While recording: the sample replayed step by step until TopicMap is wired in.
            NodeMapView(data: state == .idle ? mapData : NodeMapData.sample.revealed(steps: demoStep))
                .task(id: state) {
                    while state == .recording {
                        try? await Task.sleep(for: .seconds(4))
                        guard state == .recording else { break }
                        withAnimation(.easeOut(duration: 0.3)) { demoStep += 1 }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    AddMenu(
                        importAudio: { showingAudioPicker = true },
                        pasteTranscript: { showingPaste = true }
                    )
                    .disabled(stage != nil || state != .idle)
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                .overlay {
                    if let stage {
                        MappingBadge(stage: stage, cancel: cancelMap)
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
                .disabled(stage != nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(MapStyle.canvas.ignoresSafeArea())
        .sheet(isPresented: $showingPaste) {
            PasteTranscriptView { transcript in
                mapTranscript(transcript)
            }
        }
        .fileImporter(isPresented: $showingAudioPicker, allowedContentTypes: [.audio] + AudioImport.extensions.compactMap { UTType(filenameExtension: $0) }) { result in
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
        .onDisappear { cancelMap() }
        .onAppear {
            // The waveform's mic tap also feeds the transcriber, so the mic is opened once.
            monitor.onBuffer = transcriber.feed.append
        }
    }

    /// Copies the picked file into the app first: picked files are only readable while the
    /// picker grants access, and transcription happens after that. Each copy gets its own folder,
    /// deleted once the job ends.
    private func mapAudio(_ picked: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let copy = folder.appending(path: picked.lastPathComponent)
        do {
            let access = picked.startAccessingSecurityScopedResource()
            defer { if access { picked.stopAccessingSecurityScopedResource() } }
            guard AudioImport.extensions.contains(picked.pathExtension.lowercased()) else {
                throw MapServiceError.unsupportedAudio
            }
            if let size = try picked.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                guard size > 0 else { throw MapServiceError.emptyAudio }
                guard size <= AudioImport.maxBytes else { throw MapServiceError.tooLarge }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picked, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            mapError = error.localizedDescription
            return
        }
        makeMap(startingAt: .transcribing) { job in
            defer { try? FileManager.default.removeItem(at: folder) }
            let transcript = try await AudioTranscriber.transcribeFile(copy)
            return try await MapService.getResults(transcript: transcript) { nextStage in
                if currentJob == job { stage = nextStage }
            }
        }
    }

    private func mapTranscript(_ transcript: String) {
        makeMap(startingAt: .uploading) { job in
            try await MapService.getResults(transcript: transcript) { nextStage in
                if currentJob == job { stage = nextStage }
            }
        }
    }

    private func makeMap(startingAt first: MapStage, _ work: @escaping (UUID) async throws -> NodeMapData) {
        mappingTask?.cancel()
        let job = UUID()
        currentJob = job
        stage = first
        mappingTask = Task {
            do {
                let data = try await work(job)
                try Task.checkCancellation()
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

private struct AddMenu: View {
    var importAudio: () -> Void
    var pasteTranscript: () -> Void

    var body: some View {
        Menu {
            Button("Import audio", systemImage: "waveform", action: importAudio)
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

/// Local import limits; audio never becomes an HTTP request body.
private enum AudioImport {
    static let maxBytes = 25 * 1024 * 1024
    static let extensions: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "webm"]
}
