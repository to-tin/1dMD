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
    @State private var showingPastChats = false
    /// What the running mapping operation is doing; nil when nothing is running.
    @State private var stage: MapStage?
    @State private var mappingTask: Task<Void, Never>?
    /// Identifies the latest job, so an older one finishing late can't overwrite it.
    @State private var currentJob: UUID?
    @State private var alert: AlertInfo?
    /// Saved chats for the drawer, most recently updated first.
    @State private var chats: [SavedChat] = []
    /// The chat on screen. Recording while one is open continues it; nil means the next
    /// recording starts a new chat.
    @State private var openChat: SavedChat?
    private let store = ChatStore()
    /// Placeholder: replays the sample map one move at a time while recording,
    /// until TopicMap feeds real moves in.
    @State private var demoStep = 0
    /// When the current recording started; becomes a new chat's start date.
    @State private var recordingStarted: Date?
    /// True from Done until the last words are in, so nothing can restart the mic and wipe them.
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 0) {
            // When idle: the sample, or the open chat's map.
            // While recording: the open chat's map, or for a new chat the sample replayed
            // step by step until live mapping is wired in.
            NodeMapView(data: state == .idle || openChat != nil ? mapData : NodeMapData.sample.revealed(steps: demoStep))
                .task(id: state) {
                    while state == .recording {
                        try? await Task.sleep(for: .seconds(4))
                        guard state == .recording else { break }
                        withAnimation(.easeOut(duration: 0.3)) { demoStep += 1 }
                    }
                }
                .overlay {
                    if let stage {
                        MappingBadge(stage: stage, cancel: cancelMap)
                    } else if isFinishing {
                        FinishingBadge()
                    } else if state == .idle, let openChat, openChat.map == nil {
                        // The words were saved but the map failed.
                        VStack(spacing: 6) {
                            Text("No map yet")
                                .font(.body.weight(.medium))
                                .foregroundStyle(MapStyle.ink)
                            Text("The words are saved. Record more in this chat to try the map again.")
                                .font(.footnote)
                                .foregroundStyle(MapStyle.muted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 40)
                    }
                }
                // Past chats sits top-left and, like "+", hides while recording.
                .overlay(alignment: .topLeading) {
                    if state == .idle {
                        PastChatsButton { showingPastChats = true }
                            .disabled(isBusy)
                            .padding(16)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

            if state != .idle {
                TranscriptLine(final: transcriber.finalText, draft: transcriber.draftText, status: transcriber.status)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 12) {
                if state != .idle {
                    TimerLabel(segmentStart: segmentStart, accumulated: accumulated)
                        .frame(height: 48)
                }

                WaveformView(samples: monitor.samples)
                    .frame(height: 48)

                // "+" sits above the mic; while recording, "Done" takes its place.
                VStack(alignment: .trailing, spacing: 12) {
                    if state == .idle {
                        AddMenu(
                            importAudio: { showingAudioPicker = true },
                            pasteTranscript: { showingPaste = true }
                        )
                        .disabled(isBusy)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        DoneButton(action: finish)
                            .transition(.scale.combined(with: .opacity))
                    }

                    MicButton(state: state) {
                        toggle()
                    }
                    .disabled(isBusy)
                }
                .animation(.easeOut(duration: 0.2), value: state)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(MapStyle.canvas.ignoresSafeArea())
        .overlay {
            PastChatsDrawer(
                isOpen: $showingPastChats,
                chats: chats,
                currentID: openChat?.id,
                select: open,
                delete: delete,
                newChat: startNewChat
            )
        }
        .sheet(isPresented: $showingPaste) {
            PasteTranscriptView { transcript in
                mapTranscript(transcript)
            }
        }
        .fileImporter(isPresented: $showingAudioPicker, allowedContentTypes: [.audio] + AudioImport.extensions.compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case .success(let url): mapAudio(url)
            case .failure(let error): alert = .mapFailed(error)
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
        .onDisappear { cancelMap() }
        .onAppear {
            // The waveform's mic tap also feeds the transcriber, so the mic is opened once.
            monitor.onBuffer = transcriber.feed.append
            chats = store.all()
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
            alert = .mapFailed(error)
            return
        }
        makeMap(startingAt: .transcribing) { job in
            defer { try? FileManager.default.removeItem(at: folder) }
            let transcript = try await FileTranscriber.transcribe(copy)
            let map = try await MapService.getResults(transcript: transcript) { nextStage in
                if currentJob == job { stage = nextStage }
            }
            return (transcript, map)
        } then: { transcript, map in
            saveNewChat(transcript: transcript, map: map)
        }
    }

    private func mapTranscript(_ transcript: String) {
        makeMap(startingAt: .uploading) { job in
            let map = try await MapService.getResults(transcript: transcript) { nextStage in
                if currentJob == job { stage = nextStage }
            }
            return (transcript, map)
        } then: { transcript, map in
            saveNewChat(transcript: transcript, map: map)
        }
    }

    /// Runs one mapping job and shows its map. `then` runs only if this is still the latest job.
    private func makeMap(
        startingAt first: MapStage,
        wordsSaved: Bool = false,
        _ work: @escaping (UUID) async throws -> (transcript: String, map: NodeMapData),
        then: @escaping (String, NodeMapData) -> Void
    ) {
        mappingTask?.cancel()
        let job = UUID()
        currentJob = job
        stage = first
        mappingTask = Task {
            do {
                let result = try await work(job)
                try Task.checkCancellation()
                if currentJob == job {
                    withAnimation(.easeOut(duration: 0.3)) { mapData = result.map }
                    then(result.transcript, result.map)
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if currentJob == job { alert = .mapFailed(error, wordsSaved: wordsSaved) }
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

    private var isBusy: Bool { stage != nil || isFinishing }

    // MARK: Chats

    /// Writes a chat to disk and refreshes the drawer. Returns false (and says why) if it couldn't.
    @discardableResult
    private func persist(_ chat: SavedChat) -> Bool {
        do {
            try store.save(chat)
            chats = store.all()
            return true
        } catch {
            alert = .saveFailed(error)
            return false
        }
    }

    /// A pasted transcript or imported audio always starts its own chat.
    private func saveNewChat(transcript: String, map: NodeMapData) {
        let chat = SavedChat(transcript: transcript, map: map)
        if persist(chat) { openChat = chat }
    }

    private func open(_ chat: SavedChat) {
        cancelMap()
        openChat = chat
        withAnimation(.easeOut(duration: 0.3)) { mapData = chat.map ?? .empty }
    }

    private func startNewChat() {
        cancelMap()
        openChat = nil
        withAnimation(.easeOut(duration: 0.3)) { mapData = .sample }
    }

    private func delete(_ chat: SavedChat) {
        do {
            try store.delete(chat.id)
        } catch {
            alert = .deleteFailed(error)
            return
        }
        chats = store.all()
        if openChat?.id == chat.id { startNewChat() }
    }

    /// Saves the new words first, then asks for a map of the whole chat. If the map fails,
    /// the words are still saved, and the next time the chat is continued it's mapped again.
    private func saveRecording(_ words: String, recorded: TimeInterval, into continuing: SavedChat?, started: Date) {
        var chat = continuing ?? SavedChat(transcript: "", now: started)
        chat.append(words: words, recorded: recorded)
        guard persist(chat) else { return }
        openChat = chat
        if continuing == nil { mapData = .empty }

        let id = chat.id
        let transcript = chat.transcript
        makeMap(startingAt: .uploading, wordsSaved: true) { job in
            let map = try await MapService.getResults(transcript: transcript) { nextStage in
                if currentJob == job { stage = nextStage }
            }
            return (transcript, map)
        } then: { _, map in
            // Re-read the saved chat, so the map lands on its latest version.
            guard var latest = chats.first(where: { $0.id == id }) else { return }
            latest.setMap(map)
            if persist(latest), openChat?.id == id { openChat = latest }
        }
    }

    // MARK: Recording

    private func toggle() {
        withAnimation(.easeOut(duration: 0.2)) {
            switch state {
            case .idle:
                monitor.start()
                Task { await transcriber.start() }
                segmentStart = Date()
                recordingStarted = Date()
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

    /// Done: stops the mic, waits for the last words, then saves them to the open chat
    /// (or a new one). Silence saves nothing.
    private func finish() {
        let recorded = accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
        let started = recordingStarted ?? Date()
        // Captured now, so the words can't land in a different chat.
        let continuing = openChat
        isFinishing = true
        withAnimation(.easeOut(duration: 0.2)) {
            monitor.stop()
            segmentStart = nil
            recordingStarted = nil
            accumulated = 0
            state = .idle
        }
        Task {
            // Stopping mid-setup would leave the transcriber running, so let setup
            // (the permission prompt, a first-time model download) finish first.
            while transcriber.status == .preparing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await transcriber.stop()
            // The last phrase can still be on its way after stop() returns, so wait until
            // the words stop changing (up to 2 seconds) before reading them.
            var last = transcriber.finalText
            var steady: Duration = .zero
            var waited: Duration = .zero
            while steady < .milliseconds(300), waited < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(50))
                waited += .milliseconds(50)
                if transcriber.finalText == last {
                    steady += .milliseconds(50)
                } else {
                    last = transcriber.finalText
                    steady = .zero
                }
            }
            let words = transcriber.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            isFinishing = false
            guard !words.isEmpty else { return }
            saveRecording(words, recorded: recorded, into: continuing, started: started)
        }
    }
}

private struct AlertInfo {
    var title: String
    var message: String

    static func mapFailed(_ error: Error, wordsSaved: Bool = false) -> AlertInfo {
        AlertInfo(
            title: "Couldn't make the map",
            message: wordsSaved
                ? error.localizedDescription + "\n\nYour words are saved in Past chats. Continue the chat to try the map again."
                : error.localizedDescription
        )
    }

    static func saveFailed(_ error: Error) -> AlertInfo {
        AlertInfo(title: "Couldn't save the chat", message: error.localizedDescription)
    }

    static func deleteFailed(_ error: Error) -> AlertInfo {
        AlertInfo(title: "Couldn't delete the chat", message: error.localizedDescription)
    }
}

/// The live words: finished phrases in white, words still being heard in grey.
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

/// Ends the recording and saves it. Same look as the mic: white circle, black icon.
private struct DoneButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("Done")
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
                    .fill(Color.white)
                    .frame(width: 48, height: 48)

                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
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
            // Same idea as the mic: white circle, dark icon.
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white))
        }
        .accessibilityLabel("Add a conversation")
    }
}

/// Shown from Done until the last words are in.
private struct FinishingBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Finishing up…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Capsule().fill(MapStyle.button))
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
        .background(Capsule().fill(MapStyle.button))
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
