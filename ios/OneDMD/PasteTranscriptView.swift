import SwiftUI

/// Sheet for pasting a finished transcript. "Done" hands the text back to be mapped.
struct PasteTranscriptView: View {
    var onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .focused($focused)
                .padding(.horizontal, 16)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste a transcript…")
                            .font(.system(size: 15))
                            .foregroundStyle(MapStyle.muted)
                            .padding(.horizontal, 21)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle("Transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onDone(trimmed)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
    }
}

#Preview {
    PasteTranscriptView { _ in }
}
