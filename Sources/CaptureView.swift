import SwiftUI

/// One half of Meet on its own: a single photo from the glasses (or the
/// iPhone), matched against your network and answered with a card, here, in
/// your ear and on the lens. Shown inside `ManualView`.
struct CaptureView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @EnvironmentObject private var speech: SpeechManager
    @AppStorage("usePhoneCamera") private var usePhoneCamera = false

    @State private var busy = false
    @State private var statusLine = ""
    @State private var cards: [LookupCard] = []
    @State private var lastCapture: UIImage?
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    ProblemLabel(errorText)
                }
            }

            Section {
                Toggle("Speak the Card", isOn: $speech.speakAloud)
                if let lastCapture {
                    LabeledContent("Last Photo") {
                        Image(uiImage: lastCapture)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                    }
                }
            }

            ForEach(cards.reversed()) { card in
                LookupCardSection(card: card)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Text(statusLine.isEmpty ? sourceLine : statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                captureButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private var sourceLine: String {
        glasses.isConnected && !usePhoneCamera
            ? "Takes one photo with the glasses and looks them up."
            : "Takes one photo with the iPhone camera and looks them up."
    }

    private var captureButton: some View {
        Button {
            Task { await capture() }
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(.white)
                    Text("Looking up…")
                } else {
                    Image(systemName: "camera.fill")
                    Text("Take Photo")
                }
            }
            .font(.title3.weight(.semibold))
            .frame(minWidth: 148, minHeight: 40)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(busy)
        .accessibilityHint("Takes a photo and looks up who is in front of you")
    }

    // MARK: Flow

    private func capture() async {
        guard !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        statusLine = "Taking a photo…"

        guard
            let image = await glasses.capturePhoto(),
            let jpeg = image.jpegData(compressionQuality: 0.7)
        else {
            statusLine = ""
            errorText = "Couldn't take a photo. Check the camera in Glasses."
            return
        }
        withAnimation { lastCapture = image }
        statusLine = "Matching against your network…"

        do {
            let recognition = try await BackendAPI.recognize(jpeg: jpeg)
            guard recognition.matched, !recognition.name.isEmpty else {
                // A miss is never a dead end: enrol the same frame right now.
                await autoEnroll(jpeg: jpeg)
                return
            }

            statusLine = "Looking up \(recognition.name)…"
            // The lookup card carries the headline + talking points; the
            // recognition itself carries the spoken line for the ear.
            var card = (try? await BackendAPI.lookup(name: recognition.name))
                ?? LookupCard.empty(name: recognition.name)
            if !card.found || card.headline.isEmpty {
                card = LookupCard(
                    found: true,
                    name: recognition.name,
                    org: recognition.org,
                    headline: recognition.title,
                    lines: recognition.spoken.isEmpty ? [] : [recognition.spoken],
                    topics: [], followups: [], history: []
                )
            }
            cards.append(card)
            statusLine = "Matched in \(recognition.elapsedMs) ms"

            // Ear: TTS, routed through the glasses speakers when connected.
            let spoken = recognition.spoken.isEmpty
                ? ([card.headline] + card.lines.prefix(1)).joined(separator: ". ")
                : recognition.spoken
            speech.speak(spoken)

            // Lens: the lookup card on the glasses display.
            let headline = card.headline.isEmpty ? recognition.title : card.headline
            let lines = card.lines.isEmpty ? [recognition.spoken] : card.lines
            let name = card.name
            Task {
                await LensCards.shared.showLookup(
                    headline: headline, lines: lines, name: name
                )
            }
        } catch {
            statusLine = ""
            errorText = error.localizedDescription
        }
    }

    /// Recognize came back `matched: false`. Rather than showing nothing —
    /// which is what made the product look dead when the graph had no enrolled
    /// faces — POST the SAME frame to Enroll straight away, named from whatever
    /// Listen picked up this session, or a placeholder the user renames later.
    private func autoEnroll(jpeg: Data) async {
        statusLine = "New face. Adding them…"
        let heard = DictationManager.shared.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Ingest first, so the conversation gets to name this face before a
        // placeholder is minted for it.
        var receipt: IngestReceipt?
        if !heard.isEmpty {
            receipt = try? await BackendAPI.ingest(transcript: heard)
        }
        let real = FaceCache.usableRealName(receipt?.saved ?? "")
        let isPlaceholder = real == nil
        let name = real ?? FaceCache.nextPlaceholderName()

        do {
            let outcome = try await BackendAPI.enrollOutcome(
                name: name,
                photoJpeg: jpeg,
                role: receipt?.role ?? "",
                org: receipt?.org ?? "",
                relationship: isPlaceholder ? "just met" : "",
                notes: receipt == nil ? String(heard.prefix(300)) : ""
            )
            guard outcome.enrolled else {
                statusLine = ""
                errorText = outcome.friendlyReason
                await LensCards.shared.showGuidance(outcome.friendlyReason)
                return
            }

            FaceCache.store(jpeg, for: outcome.name)
            if isPlaceholder { FaceCache.markPlaceholder(outcome.name) }

            var lines: [String] = []
            if let receipt, !receipt.topics.isEmpty {
                lines.append("Talked about \(receipt.topics.joined(separator: ", ")).")
            }
            if lines.isEmpty {
                lines.append(
                    isPlaceholder
                        ? "Saved as \(outcome.name). Name them in People."
                        : "Face saved. Thread will know them next time."
                )
            }

            cards.append(
                LookupCard(
                    found: true,
                    name: outcome.name,
                    org: receipt?.org ?? "",
                    headline: outcome.attachedToExisting
                        ? "Face linked to \(outcome.name)"
                        : "New face, added as \(outcome.name)",
                    lines: lines,
                    topics: receipt?.topics ?? [],
                    followups: receipt?.followups ?? [],
                    history: []
                )
            )
            statusLine = outcome.attachedToExisting
                ? "Face linked to \(outcome.name)."
                : "\(outcome.name) added."
            speech.speak(
                isPlaceholder
                    ? "New face. Added to your network."
                    : "New face. \(outcome.name), added to your network."
            )
            await LensCards.shared.showNewFace(
                name: outcome.name,
                detail: lines.first ?? "",
                merged: outcome.attachedToExisting
            )
        } catch {
            statusLine = ""
            errorText = error.localizedDescription
            await LensCards.shared.showGuidance("Couldn't save that face. Check the Glasses tab.")
        }
    }
}

// MARK: - Lookup card

/// One card as a list section: who they are, what to say next, and what is
/// still owed.
struct LookupCardSection: View {
    let card: LookupCard

    var body: some View {
        Section {
            PersonRow(name: card.name, subtitle: card.org)
            if !card.headline.isEmpty {
                Text(card.headline)
            }
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
            if !card.topics.isEmpty {
                labelled("Topics", card.topics.joined(separator: ", "))
            }
            if !card.followups.isEmpty {
                labelled("You Owe Them", card.followups.joined(separator: "\n"))
            }
        } header: {
            Text(card.date, style: .time)
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
