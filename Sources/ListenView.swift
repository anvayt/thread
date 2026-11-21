import SwiftUI

/// The other half of Meet on its own: hold the button while someone talks,
/// watch the transcript build, then save it. The backend works out who was
/// speaking, where they work, what was discussed and what was promised.
/// Shown inside `ManualView`.
struct ListenView: View {
    /// Shared on purpose: the audio engine and its input tap are process-wide,
    /// so every screen drives the same manager rather than fighting over the
    /// input node.
    @ObservedObject private var dictation = DictationManager.shared
    @State private var receipts: [IngestReceipt] = []
    @State private var sending = false
    @State private var errorText: String?
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                holdButton
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                Text(hint)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            Section("Transcript") {
                Text(dictation.transcript.isEmpty ? "Nothing yet." : dictation.transcript)
                    .foregroundStyle(dictation.transcript.isEmpty ? .secondary : .primary)
                if !dictation.isUsable {
                    ProblemLabel("Thread can't listen. Allow the microphone and speech recognition in Settings, or type what was said with the keyboard button.")
                }
                if let errorText = errorText ?? dictation.errorText {
                    ProblemLabel(errorText)
                }
            }

            if !dictation.transcript.isEmpty, !dictation.isRecording {
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Save")
                            if sending {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(sending)
                    Button("Discard", role: .destructive) {
                        dictation.reset()
                    }
                }
            }

            ForEach(receipts.reversed()) { receipt in
                ReceiptSection(receipt: receipt)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draft = dictation.transcript
                    editing = true
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Type instead")
            }
        }
        .sheet(isPresented: $editing) {
            typeSheet
        }
        .onDisappear {
            if dictation.isRecording { _ = dictation.stop() }
        }
    }

    private var hint: String {
        if dictation.isRecording {
            return "Listening. Let go when they are done."
        }
        if dictation.transcript.isEmpty {
            return "Hold while someone introduces themselves."
        }
        return "Save it, or hold again to add more."
    }

    /// Press and hold, like a walkie-talkie. A plain `Button` cannot report
    /// the press and the release separately, so this is a gesture on a shape.
    private var holdButton: some View {
        Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 96, height: 96)
            .glassEffect(
                .regular.tint(dictation.isRecording ? .red : .accentColor).interactive(),
                in: .circle
            )
        .scaleEffect(dictation.isRecording ? 1 + dictation.level * 0.15 : 1)
        .animation(.easeOut(duration: 0.15), value: dictation.level)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !dictation.isRecording, !sending else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await dictation.start() }
                }
                .onEnded { _ in
                    guard dictation.isRecording else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    _ = dictation.stop()
                }
        )
        .accessibilityLabel("Hold to listen")
        .accessibilityAddTraits(.isButton)
    }

    private var typeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 180)
                } footer: {
                    Text("Type or paste what was said. It is saved the same way as a transcript.")
                }
            }
            .navigationTitle("Type What Was Said")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        dictation.setTranscript(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        editing = false
                    }
                }
            }
        }
    }

    // MARK: Flow

    private func submit() async {
        // Freeze first: the text on screen at the moment of tapping is exactly
        // the text that goes to the graph, with no late recogniser result able
        // to rewrite it in flight.
        let text = dictation.seal()
        guard !text.isEmpty, !sending else { return }
        sending = true
        errorText = nil
        defer { sending = false }

        do {
            let receipt = try await BackendAPI.ingest(transcript: text)
            receipts.append(receipt)
            dictation.reset()
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            let name = receipt.saved
            if !name.isEmpty {
                let note = receipt.newPerson
                    ? "\(name) added to your network"
                    : "\(name) updated"
                Task { await LensCards.shared.showNote(note) }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Ingest receipt

/// What saving a transcript changed, as a list section.
struct ReceiptSection: View {
    let receipt: IngestReceipt

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.saved.isEmpty ? "Saved, with no name" : receipt.saved)
                        .font(.headline)
                    if !receipt.org.isEmpty {
                        Text(receipt.org)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !receipt.saved.isEmpty {
                    Text(receipt.newPerson ? "New" : "Updated")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !receipt.topics.isEmpty {
                labelled("Topics", receipt.topics.joined(separator: ", "))
            }
            if !receipt.followups.isEmpty {
                labelled("Follow-ups", receipt.followups.joined(separator: "\n"))
            }
        } header: {
            Text(receipt.date, style: .time)
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}
