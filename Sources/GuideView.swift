import SwiftUI

// MARK: - Welcome

/// The first thing Thread shows, once, the way Apple's own apps introduce
/// themselves: what it does in four lines and a Continue button. The
/// permission prompts wait until it is closed.
struct WelcomeView: View {
    static let seenKey = "hasSeenWelcome"

    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 44) {
                    VStack(spacing: 16) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text("Welcome to Thread")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 48)

                    VStack(alignment: .leading, spacing: 28) {
                        FeatureRow(
                            systemImage: "person.wave.2",
                            title: "Meet Someone",
                            text: "Press Meet, or the capture button on your glasses, and let them introduce themselves. Thread takes one photo and listens until you press again."
                        )
                        FeatureRow(
                            systemImage: "person.text.rectangle",
                            title: "Know Them Next Time",
                            text: "When you see them again, their name and what to say next appear on the lens, in your ear and on your phone."
                        )
                        FeatureRow(
                            systemImage: "magnifyingglass",
                            title: "Ask Your Network",
                            text: "Search in plain words, like who you met working on payments."
                        )
                        FeatureRow(
                            systemImage: "lock",
                            title: "Kept on Your Own Computer",
                            text: "Faces are matched by a backend you run yourself, never by an outside face service."
                        )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 12) {
                Text("Next, Thread asks to use the microphone and speech recognition.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - How Thread works

/// What Thread does and how, in plain words, plus sample people to try it
/// with. This is the one screen that is allowed to explain; the working
/// screens keep to a short footer.
struct GuideView: View {
    @State private var demoStatus: String?
    @State private var demoFailed = false
    @State private var demoBusy = false
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                step(1, "Tap Meet. Thread starts listening straight away and takes one photo at the same time.")
                step(2, "It listens until you press Meet or the capture button again, so a long introduction is never cut short. It stops by itself after \(Int(TurnTiming.pressCeiling / 60)) minutes. To have it stop when they go quiet instead, choose Stop Listening in Meet's More menu.")
                step(3, "The photo is compared with every face in your network. If it matches, you get their card: who they are and what to say next.")
                step(4, "If it doesn't match, the same photo is added on the spot, under the name they said, or as “New contact” with a number until you name them.")
                step(5, "What they said is filed under that person: their company, what you talked about, and anything you promised.")
            } header: {
                Text("How Meet Works")
            } footer: {
                Text("The card is shown in the app and spoken. Glasses with a display show it on the lens as well.")
            }

            Section("Other Ways In") {
                FeatureRow(systemImage: "repeat", title: "Keep Going", text: "The button to the right of Meet repeats Meet until you turn it off.")
                FeatureRow(systemImage: "button.programmable", title: "The Glasses' Buttons", text: "Press the capture button or double-tap the temple to start Meet, and press again to stop listening. You can switch this off in Glasses.")
                FeatureRow(systemImage: "ellipsis.circle", title: "Photo Only and Listen Only", text: "In Meet's More menu: one photo on its own, or a transcript while you hold the button.")
                FeatureRow(systemImage: "magnifyingglass", title: "Search", text: "Ask about the people you've met in plain words.")
            }

            Section("On the Lens") {
                Text("Only glasses with a display show a card. Other glasses take the photo and speak the first line.")
                Text("A card shows a name, a role and company, and one or two things to say. “more” pages through the rest and “dismiss” clears it. It clears itself after 14 seconds.")
                Text("If there is no face in the photo, the lens says so. Thread never guesses a name.")
            }

            Section("The Neural Band") {
                Text("A pinch presses a button on the card that is showing. It cannot start a capture, scroll or swipe, and does nothing until the display has started.")
            }

            Section("Privacy") {
                Text("Faces are matched on your own backend. No photo goes to an outside face service.")
                Text("A photo that is only being recognised is used once and dropped. The photo you add someone from is kept, on this phone and on your backend.")
                Text("Audio is never sent to your backend, only the transcribed text. The backend keeps that text and sends it to a language model to pull out names, companies and follow-ups.")
                Text("Nothing is transcribed until you start a capture. The microphone is kept ready while the app is open, so the first words aren't lost.")
                Text("With Include the Moment Before on, the last 5 or 10 seconds are kept in the iPhone's memory, overwritten as they pass, and transcribed only when you start Meet.")
                Text("Forget removes a person's face, their notes and every meeting.")
            }

            demoSection
        }
        .navigationTitle("How Thread Works")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Demo

    private var demoSection: some View {
        Section {
            Button("Add Sample People") {
                Task { await runDemoAction("Adding…") { try await BackendAPI.seed() } }
            }
            .disabled(demoBusy)
            Button("Delete Everything", role: .destructive) {
                confirmReset = true
            }
            .disabled(demoBusy)

            if let demoStatus {
                Text(demoStatus)
                    .foregroundStyle(demoFailed ? Color.red : Color.secondary)
            }
        } header: {
            Text("Try It")
        } footer: {
            Text("Add the sample people, then Meet someone new twice: the second time, Thread should know them. Delete Everything empties the backend this phone is connected to.")
        }
        .confirmationDialog(
            "Delete everything?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await runDemoAction("Deleting…") { try await BackendAPI.reset() } }
            }
        } message: {
            Text("Every person, face and meeting is deleted from the backend.")
        }
    }

    // MARK: Pieces

    /// A numbered step. These are real sequences, so the numbers carry
    /// information.
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }

    private func runDemoAction(
        _ progress: String, _ action: @escaping () async throws -> Void
    ) async {
        demoBusy = true
        demoFailed = false
        demoStatus = progress
        defer { demoBusy = false }
        do {
            try await action()
            demoStatus = "Done."
        } catch {
            demoFailed = true
            demoStatus = "That didn't work. \(error.localizedDescription)"
        }
    }
}
