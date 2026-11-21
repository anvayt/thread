import SwiftUI
import UIKit

// MARK: - Result model

/// One pass of the Meet loop, rendered in-app.
struct MeetResult: Identifiable {
    enum Kind {
        case recognised
        case newFace
        case merged
        case renamed
        case guidance
        case failed
    }

    let id = UUID()
    let kind: Kind
    let name: String
    let role: String
    let org: String
    let headline: String
    let lines: [String]
    let topics: [String]
    let followups: [String]
    let transcript: String
    let placeholder: Bool
    /// Which camera produced the frame this pass used.
    let frameSource: String
    /// Which microphone the transcript came from. Empty when nothing was heard.
    let micSource: String
    /// The auto-generated name this pass retired, if the conversation finally
    /// told us who the face belongs to.
    let renamedFrom: String
    let date = Date()

    init(
        kind: Kind,
        name: String,
        role: String = "",
        org: String = "",
        headline: String,
        lines: [String] = [],
        topics: [String] = [],
        followups: [String] = [],
        transcript: String = "",
        placeholder: Bool = false,
        renamedFrom: String = "",
        frameSource: String = "",
        micSource: String = ""
    ) {
        self.frameSource = frameSource
        self.micSource = micSource
        self.kind = kind
        self.name = name
        self.role = role
        self.org = org
        self.headline = headline
        self.lines = lines
        self.topics = topics
        self.followups = followups
        self.transcript = transcript
        self.placeholder = placeholder
        self.renamedFrom = renamedFrom
    }

    var subhead: String {
        [role, org].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var badge: String {
        switch kind {
        case .recognised: return "Known"
        case .newFace: return "New"
        case .merged: return "Face linked"
        case .renamed: return "Named"
        case .guidance: return "Try again"
        case .failed: return "Failed"
        }
    }

    /// True for the two kinds that are not a person: something went wrong and
    /// `name` holds a sentence about it.
    var isProblem: Bool {
        kind == .guidance || kind == .failed
    }
}

// MARK: - Resolved identity

/// Who the graph settled on for the face in front of the camera, after the
/// transcript has had its say.
///
/// The whole point of this type is that a name is decided ONCE, from the
/// transcript first and a placeholder only as a fallback — the two paths that
/// used to disagree (auto-enroll minting "New contact NN" while `ingest`
/// separately created the real person) now produce one value.
private struct ResolvedIdentity {
    var name: String
    var role: String = ""
    var org: String = ""
    var receipt: IngestReceipt?
    /// Set when this pass retired an auto-generated placeholder.
    var renamedFrom: String = ""
    var isPlaceholder: Bool = false

    var subhead: String {
        [role, org].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Engine

/// The one-tap loop: speech (+ frame, concurrently) → recognise → (auto-enrol
/// on a miss) → ingest → lens + ear + app.
///
/// It lives outside the view so auto-repeat survives a tab switch and so the
/// ordering guarantees stay in one place.
///
/// The microphone opens FIRST and the frame is grabbed alongside it. Taking the
/// photo first cost a couple of seconds before anyone was being listened to,
/// which is exactly where "hi, I'm Sam" lands — the words that matter most were
/// the ones being dropped. The camera can't fight the mic for the route because
/// `PhoneCameraFallback` never touches the audio session and the recognition
/// task runs off an already-primed engine.
///
/// A frame that never arrives no longer aborts anything: the conversation is
/// still transcribed and still ingested.
@MainActor
final class MeetEngine: ObservableObject {
    static let shared = MeetEngine()

    enum Phase: Equatable {
        case idle
        // There is no `framing` phase any more — the frame is taken alongside
        // the conversation, never in front of it.
        case listening
        case thinking

        var isBusy: Bool { self != .idle }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusLine = ""
    @Published private(set) var results: [MeetResult] = []
    @Published private(set) var lastCapture: UIImage?
    @Published private(set) var errorText: String?
    @Published var autoRepeat = false {
        didSet { autoRepeat ? startAutoLoop() : stopAutoLoop() }
    }
    /// UserDefaults key for how a turn ends. 0 means only a press ends it.
    static let stopAfterQuietKey = "stopAfterQuiet"
    /// How a turn ends: 0 means only a press does (the capture button on the
    /// glasses, or Done), which is the default. Any other value is the seconds
    /// of quiet that end it. Set from Meet's More menu, and kept.
    @Published var trailingSilence: Double =
        UserDefaults.standard.object(forKey: MeetEngine.stopAfterQuietKey) as? Double ?? 0 {
        didSet { UserDefaults.standard.set(trailingSilence, forKey: Self.stopAfterQuietKey) }
    }
    /// True when only a press ends a turn.
    var stopsOnPress: Bool { trailingSilence <= 0 }
    /// Which camera produced the frame for the pass in flight.
    @Published private(set) var frameSource = ""
    /// Which microphone the transcript for the pass in flight came from.
    @Published private(set) var micSource = ""

    private let dictation = DictationManager.shared
    private let ear = GlassesEar.shared
    private var autoTask: Task<Void, Never>?
    /// The last transcript already folded into someone's record. Guards the
    /// "reuse whatever Listen captured this session" fallback from attaching
    /// the previous person's words to the next face.
    private var shownEarly: Set<String> = []
    private var lastConsumedTranscript = ""

    private init() {}

    // MARK: Auto-repeat

    private func startAutoLoop() {
        autoTask?.cancel()
        autoTask = Task { @MainActor [weak self] in
            while let self, self.autoRepeat, !Task.isCancelled {
                await self.runOnce()
                guard self.autoRepeat else { break }
                // Breather between passes so the wearer can read the lens.
                for _ in 0..<40 {
                    guard self.autoRepeat, !Task.isCancelled else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    private func stopAutoLoop() {
        autoTask?.cancel()
        autoTask = nil
    }

    // MARK: Dependencies

    private weak var glasses: GlassesManager?
    private weak var speech: SpeechManager?

    func bind(glasses: GlassesManager, speech: SpeechManager) {
        self.glasses = glasses
        self.speech = speech
    }

    // MARK: The loop

    /// Ends the current turn right now. The user is never trapped waiting for
    /// silence they can't produce.
    func finishListening() {
        guard phase == .listening else { return }
        dictation.stop()
    }

    /// A tap on the glasses, passed on by `GlassesManager`: the Meet button
    /// without the phone. Returns false when a pass was already running.
    @discardableResult
    func glassesTapped() -> Bool {
        guard !phase.isBusy, glasses != nil else { return false }
        Task { await runOnce() }
        return true
    }

    func runOnce() async {
        guard !phase.isBusy, let glasses else { return }
        errorText = nil
        frameSource = ""
        micSource = ""
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        // Anything the Listen pipeline already captured this session, in case
        // they introduced themselves before the tap.
        let carried = dictation.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1 — the frame, in the background, starting now. Nothing below waits on
        // it until the conversation is over, and a failure here is not fatal.
        let frameTask = Task { @MainActor [weak self] () -> Data? in
            let image = await glasses.capturePhoto()
            self?.frameSource = glasses.lastFrameSource
            guard let image, let jpeg = image.jpegData(compressionQuality: 0.7)
            else { return nil }
            self?.lastCapture = image
            return jpeg
        }

        // 1b — recognise the moment the frame lands, without waiting for the
        // conversation. Someone you already know should get their card now;
        // standing there while they re-introduce themselves is the bug.
        let earlyTask = Task { @MainActor [weak self] () -> Recognition? in
            guard let jpeg = await frameTask.value else { return nil }
            guard let hit = try? await BackendAPI.recognize(jpeg: jpeg),
                  hit.matched, !hit.name.isEmpty
            else { return nil }
            await self?.presentEarlyLookup(hit)
            return hit
        }

        // 2 — listen, for exactly as long as they talk. The engine and its tap
        // are already running; this only opens a recognition task. A known face
        // has already been shown by now; anything new said here still lands in
        // the graph.
        //
        // The glasses listen as well when that is switched on in Glasses. Their
        // audio arrives with the camera stream, so on the first pass it starts
        // a few seconds late; the phone covers that gap.
        let glassesListening = glasses.listensThroughGlasses
        var glassesHeard: (@MainActor () -> Int)?
        if glassesListening {
            ear.begin()
            glassesHeard = { [ear] in ear.transcript.count }
        }

        phase = .listening
        statusLine = "Listening. Let them introduce themselves."
        var fresh = await dictation.recordUntilSilence(
            trailingSilence: stopsOnPress ? TurnTiming.trailingSilence : trailingSilence,
            ceiling: stopsOnPress ? TurnTiming.pressCeiling : TurnTiming.hardCeiling,
            endsOnSilence: !stopsOnPress,
            includeMomentBefore: true,
            alsoHeard: glassesHeard
        )
        let early = await earlyTask.value

        // Two microphones, one transcript: whichever caught more words. A tie
        // goes to the phone, which is the better microphone when it is out.
        if !fresh.isEmpty { micSource = "phone microphone" }
        if glassesListening {
            let fromGlasses = await ear.end()
            if GlassesEar.wordCount(fromGlasses) > GlassesEar.wordCount(fresh) {
                // Put it on screen too, so what is shown is what gets posted.
                dictation.setTranscript(fromGlasses)
                fresh = fromGlasses
                micSource = "glasses microphone"
            }
        }

        var transcript = fresh
        if transcript.isEmpty, !carried.isEmpty, carried != lastConsumedTranscript {
            transcript = carried
        }
        if !transcript.isEmpty { lastConsumedTranscript = transcript }
        // What this pass will hand to the graph, next to what is on screen.
        // The two must be identical; if they ever aren't, this is the line that
        // says so.
        print(
            "[thread] capture done — heard(\(fresh.count))=\"\(fresh)\" | "
                + "using(\(transcript.count))=\"\(transcript)\" | "
                + "on screen(\(dictation.transcript.count))=\"\(dictation.transcript)\""
        )

        // 3 — who is it? Only now do we need the picture.
        phase = .thinking
        statusLine = "Matching against your network…"
        guard let jpeg = await frameTask.value else {
            await handleFrameless(transcript: transcript)
            phase = .idle
            return
        }

        do {
            let recognition: Recognition
            if let early {
                recognition = early
            } else {
                recognition = try await BackendAPI.recognize(jpeg: jpeg)
            }
            if recognition.matched, !recognition.name.isEmpty {
                await handleMatch(recognition, transcript: transcript, jpeg: jpeg)
            } else {
                await handleMiss(transcript: transcript, jpeg: jpeg)
            }
        } catch {
            errorText = error.localizedDescription
            statusLine = "Backend didn't answer."
            results.append(
                MeetResult(
                    kind: .failed, name: "Couldn't reach the backend",
                    headline: error.localizedDescription, transcript: transcript
                )
            )
            await LensCards.shared.showGuidance("Can't reach the backend. Check the Glasses tab.")
        }

        phase = .idle
        if errorText == nil { statusLine = "" }
        // Someone may have just been added: hint their name from now on.
        Task { await dictation.refreshHintNames() }
    }

    // MARK: No frame

    /// The camera came back empty. This used to abort the pass before the
    /// microphone had even opened; now the conversation has already happened, so
    /// the only thing missing is the face — ingest what was said and say plainly
    /// which part failed.
    private func handleFrameless(transcript: String) async {
        let blocked = glasses?.cameraBlocked ?? false
        // A blocked camera already has a standing row on the Meet screen, with
        // the button to Settings, so it is not said a second time here.
        errorText = blocked
            ? nil
            : "The camera didn't return a photo. What they said was still saved."
        statusLine = blocked ? "Camera access is off." : "No photo. The conversation was kept."

        var receipt: IngestReceipt?
        if !transcript.isEmpty {
            receipt = try? await BackendAPI.ingest(transcript: transcript)
        }
        let named = FaceCache.usableRealName(receipt?.saved ?? "") ?? ""

        var lines: [String] = []
        if transcript.isEmpty {
            lines.append("Nothing was said either. Tap Meet to try again.")
        } else if named.isEmpty {
            lines.append("What they said was saved.")
        } else {
            lines.append("Saved to \(named). The face wasn't captured, so add it from People.")
        }
        if blocked {
            lines.append("Turn on Camera for Thread in Settings, then tap Meet again.")
        }

        results.append(
            MeetResult(
                kind: .guidance,
                name: blocked ? "Camera is off for Thread" : "No photo, conversation kept",
                headline: blocked
                    ? "iOS is blocking the camera, so there was no face to match."
                    : "The camera didn't return a frame.",
                lines: lines,
                topics: receipt?.topics ?? [],
                followups: receipt?.followups ?? [],
                transcript: transcript,
                frameSource: frameSource,
                micSource: micSource
            )
        )
        await LensCards.shared.showGuidance(
            blocked
                ? "Camera is off for Thread. The conversation was still saved."
                : "No photo. The conversation was still saved."
        )
    }

    // MARK: Branches

    /// A known face, surfaced the instant recognition lands — lens, voice and
    /// card — while the microphone keeps listening for anything new.
    @MainActor
    private func presentEarlyLookup(_ hit: Recognition) async {
        guard !shownEarly.contains(hit.name) else { return }
        shownEarly.insert(hit.name)

        let card = (try? await BackendAPI.lookup(name: hit.name)) ?? nil
        let lines = card?.lines ?? []
        let headline = card?.headline ?? hit.name

        statusLine = "\(hit.name). You've met before."
        results.insert(
            MeetResult(
                kind: .recognised,
                name: hit.name,
                role: hit.role,
                org: hit.org,
                headline: headline,
                lines: lines
            ),
            at: 0
        )
        await LensCards.shared.showLookup(
            headline: headline,
            subhead: [hit.role, hit.org].filter { !$0.isEmpty }
                .joined(separator: ", "),
            lines: lines,
            name: hit.name
        )
        speech?.speak(lines.first ?? headline)
    }

    private func handleMatch(
        _ recognition: Recognition, transcript: String, jpeg: Data
    ) async {
        let matchedPlaceholder = FaceCache.isPlaceholder(recognition.name)
        statusLine = matchedPlaceholder
            ? "Seen before. Listening for their name…"
            : "Looking up \(recognition.name)…"

        var who = ResolvedIdentity(
            name: recognition.name,
            role: recognition.role,
            org: recognition.org,
            isPlaceholder: matchedPlaceholder
        )

        if !transcript.isEmpty {
            if matchedPlaceholder {
                // The face is on an auto-named node. Pinning the conversation
                // to that name with `speaker` is exactly what kept "New contact
                // 03" collecting topics while a second node carried the real
                // name — so let the extractor try for a name FIRST.
                let free = try? await BackendAPI.ingest(transcript: transcript)
                if let free, let real = FaceCache.usableRealName(free.saved) {
                    who.receipt = free
                    if !free.role.isEmpty { who.role = free.role }
                    if !free.org.isEmpty { who.org = free.org }
                    await reconcile(placeholder: recognition.name, to: real, jpeg: jpeg, into: &who)
                } else {
                    // Still nobody named — keep the conversation attached to
                    // the placeholder rather than dropping it on the floor.
                    who.receipt = try? await BackendAPI.ingest(
                        transcript: transcript, speaker: recognition.name
                    )
                }
            } else {
                // A known name pins the conversation, so a first name in the
                // transcript can't spawn a duplicate node.
                who.receipt = try? await BackendAPI.ingest(
                    transcript: transcript, speaker: recognition.name
                )
                await fillProfile(&who, jpeg: jpeg)
            }
        }

        FaceCache.store(jpeg, for: who.name)

        let card = (try? await BackendAPI.lookup(name: who.name))
            ?? LookupCard.empty(name: who.name)
        if who.org.isEmpty { who.org = card.org }

        let receipt = who.receipt
        var lines = card.lines
        if lines.isEmpty, !recognition.spoken.isEmpty, who.renamedFrom.isEmpty {
            lines = [recognition.spoken]
        }
        if lines.isEmpty, let receipt, !receipt.topics.isEmpty {
            lines = ["You talked about \(receipt.topics.joined(separator: ", "))."]
        }
        let followups = card.followups.isEmpty ? (receipt?.followups ?? []) : card.followups
        if lines.isEmpty, let owed = followups.first {
            lines = ["You owe them: \(owed)."]
        }
        if lines.isEmpty { lines = ["You've met before. No notes yet."] }

        let renamed = !who.renamedFrom.isEmpty
        let headline = renamed
            ? "\(who.renamedFrom) is really \(who.name)"
            : (card.headline.isEmpty ? recognition.title : card.headline)

        results.append(
            MeetResult(
                kind: renamed ? .renamed : .recognised,
                name: who.name,
                role: who.role,
                org: who.org,
                headline: headline,
                lines: lines,
                topics: card.topics.isEmpty ? (receipt?.topics ?? []) : card.topics,
                followups: followups,
                transcript: transcript,
                placeholder: who.isPlaceholder,
                renamedFrom: who.renamedFrom,
                frameSource: frameSource,
                micSource: micSource
            )
        )
        statusLine = renamed
            ? "Renamed \(who.renamedFrom) to \(who.name)."
            : "Matched in \(recognition.elapsedMs) ms"

        if renamed {
            speech?.speak("That's \(who.name). Renamed from \(who.renamedFrom).")
        } else {
            speech?.speak(
                recognition.spoken.isEmpty
                    ? ([headline] + lines.prefix(1)).joined(separator: ". ")
                    : recognition.spoken
            )
        }
        await LensCards.shared.showLookup(
            headline: who.name,
            subhead: who.subhead,
            lines: lines + followups.map { "You owe them: \($0)" },
            name: who.name
        )
    }

    // MARK: Identity plumbing

    /// Retire an auto-generated placeholder in favour of the name the
    /// conversation supplied.
    ///
    /// At the moment this is called the graph holds TWO nodes: the placeholder
    /// carries the face vector, and `ingest` has just put the topics and the
    /// interaction on a node under the real name. `Enroll` merges by name, so
    /// replaying the captured frame under the real name moves the face onto the
    /// right node (`attached_to_existing: true`) and `forget` then removes the
    /// placeholder — leaving exactly one node with both the face and the
    /// topics.
    private func reconcile(
        placeholder: String, to real: String, jpeg: Data, into who: inout ResolvedIdentity
    ) async {
        statusLine = "That's \(real). Merging \(placeholder)…"

        guard
            let outcome = try? await BackendAPI.enrollOutcome(
                name: real, photoJpeg: jpeg, role: who.role, org: who.org
            ),
            outcome.enrolled
        else {
            // The face didn't move. Deleting the placeholder now would take the
            // only node holding the face vector with it, so leave both alone.
            return
        }

        try? await BackendAPI.forget(name: placeholder)
        FaceCache.move(from: placeholder, to: outcome.name)
        FaceCache.store(jpeg, for: outcome.name)
        FaceCache.clearPlaceholder(placeholder)

        who.name = outcome.name
        who.renamedFrom = placeholder
        who.isPlaceholder = false
    }

    /// Retire a placeholder that was created from this exact frame before the
    /// conversation supplied a real name — the "a placeholder already exists
    /// earlier in the flow" case, which happens when an earlier pass (or the
    /// Capture tab) banked the same still while nobody had introduced
    /// themselves yet.
    ///
    /// Matching on the stored bytes is deliberate: it fires only for the frame
    /// we know is the same person, so two different strangers can never be
    /// merged by a near-miss heuristic.
    private func retireStalePlaceholder(
        holding jpeg: Data, for who: inout ResolvedIdentity
    ) async {
        let stale = FaceCache.placeholderNames.first {
            $0.caseInsensitiveCompare(who.name) != .orderedSame
                && FaceCache.frame(for: $0) == jpeg
        }
        guard let stale else { return }
        statusLine = "Merging \(stale) into \(who.name)…"
        try? await BackendAPI.forget(name: stale)
        FaceCache.forget(stale)
        FaceCache.clearPlaceholder(stale)
        who.renamedFrom = stale
    }

    /// Write a job title back onto the person's record.
    ///
    /// `ingest` fills `org` and `role` itself when the record has none yet,
    /// and reports what the record then holds. Replaying a newly learned
    /// title through `enroll` (which accepts optional role/org and merges
    /// onto the existing person by name) makes sure it lands even if the
    /// backend only reported it. The round trip is skipped when there is no
    /// new title, which is why a normal matched conversation still costs
    /// exactly one ingest.
    private func fillProfile(_ who: inout ResolvedIdentity, jpeg: Data) async {
        guard let receipt = who.receipt else { return }
        if !receipt.org.isEmpty { who.org = receipt.org }

        let role = receipt.role.trimmingCharacters(in: .whitespaces)
        guard !role.isEmpty, role != who.role else { return }

        _ = try? await BackendAPI.enrollOutcome(
            name: who.name, photoJpeg: jpeg, role: role, org: who.org
        )
        who.role = role
    }

    /// A miss is never a dead end. The same frame is enrolled immediately —
    /// under the name the conversation gave us if there was one, otherwise a
    /// placeholder the user renames later from Network.
    private func handleMiss(transcript: String, jpeg: Data) async {
        // Ingest FIRST. The transcript is the only thing that can give this
        // face a real name, and minting "New contact NN" before asking is what
        // stranded placeholders with a full history and no identity.
        var receipt: IngestReceipt?
        if !transcript.isEmpty {
            statusLine = "New face. Listening for their name…"
            receipt = try? await BackendAPI.ingest(transcript: transcript)
        }

        var who = ResolvedIdentity(name: "", receipt: receipt)
        if let real = FaceCache.usableRealName(receipt?.saved ?? "") {
            who.name = real
            who.role = receipt?.role ?? ""
            who.org = receipt?.org ?? ""
        } else {
            // Only now, and only because nobody said a name.
            who.name = FaceCache.nextPlaceholderName()
            who.isPlaceholder = true
        }
        let isPlaceholder = who.isPlaceholder
        statusLine = "Adding \(who.name) to your network…"

        do {
            let outcome = try await BackendAPI.enrollOutcome(
                name: who.name,
                photoJpeg: jpeg,
                role: who.role,
                org: who.org,
                relationship: isPlaceholder ? "just met" : "",
                // Only carry the raw line when ingest didn't already structure
                // it, so auto-enroll never clobbers better data.
                notes: receipt == nil ? String(transcript.prefix(300)) : ""
            )

            guard outcome.enrolled else {
                // "no face detected" is guidance, not a failure banner.
                statusLine = "No face in that frame."
                results.append(
                    MeetResult(
                        kind: .guidance,
                        name: "No face in that frame",
                        headline: outcome.friendlyReason,
                        lines: transcript.isEmpty
                            ? []
                            : [
                                who.isPlaceholder
                                    ? "What they said was still saved."
                                    : "What \(who.name) said was still saved."
                            ],
                        topics: receipt?.topics ?? [],
                        followups: receipt?.followups ?? [],
                        transcript: transcript,
                        frameSource: frameSource,
                        micSource: micSource
                    )
                )
                await LensCards.shared.showGuidance(outcome.friendlyReason)
                speech?.speak("Couldn't see a face. Get a little closer.")
                return
            }

            who.name = outcome.name
            FaceCache.store(jpeg, for: who.name)
            if isPlaceholder {
                FaceCache.markPlaceholder(who.name)
            } else {
                // The conversation named them, but an earlier pass may have
                // already banked this very frame under a placeholder — retire
                // it so the face and the topics end up on one node.
                await retireStalePlaceholder(holding: jpeg, for: &who)
            }

            var lines: [String] = []
            if let receipt, !receipt.topics.isEmpty {
                lines.append("Talked about \(receipt.topics.joined(separator: ", ")).")
            }
            if !who.org.isEmpty {
                lines.append("Works at \(who.org).")
            }
            if let owed = receipt?.followups.first {
                lines.append("You owe them: \(owed).")
            }
            if lines.isEmpty {
                lines.append(
                    isPlaceholder
                        ? "Saved as \(who.name). Name them in People."
                        : "Face saved. Thread will know them next time."
                )
            }

            let renamed = !who.renamedFrom.isEmpty
            let kind: MeetResult.Kind = renamed
                ? .renamed
                : (outcome.attachedToExisting ? .merged : .newFace)
            let headline: String
            if renamed {
                headline = "\(who.renamedFrom) is really \(who.name)"
            } else if outcome.attachedToExisting {
                headline = "Face linked to \(who.name)"
            } else {
                headline = "New face, added as \(who.name)"
            }

            results.append(
                MeetResult(
                    kind: kind,
                    name: who.name,
                    role: who.role,
                    org: who.org,
                    headline: headline,
                    lines: lines,
                    topics: receipt?.topics ?? [],
                    followups: receipt?.followups ?? [],
                    transcript: transcript,
                    placeholder: isPlaceholder,
                    renamedFrom: who.renamedFrom,
                    frameSource: frameSource,
                    micSource: micSource
                )
            )
            statusLine = outcome.attachedToExisting
                ? "Face linked to \(who.name)."
                : "\(who.name) added."

            speech?.speak(
                isPlaceholder
                    ? "New face. Added to your network. Rename them later."
                    : "New face. \(who.name), added to your network."
            )
            await LensCards.shared.showNewFace(
                name: who.name,
                detail: lines.first ?? "",
                merged: outcome.attachedToExisting
            )
        } catch {
            errorText = error.localizedDescription
            results.append(
                MeetResult(
                    kind: .failed, name: "Couldn't add that face",
                    headline: error.localizedDescription, transcript: transcript
                )
            )
            await LensCards.shared.showGuidance("Couldn't save that face. Check the Glasses tab.")
        }
    }

    func clearResults() {
        results.removeAll()
        lastCapture = nil
        errorText = nil
    }
}

// MARK: - View

/// The primary screen. One button captures a frame and what they say, for as
/// long as they keep talking (see `TurnTiming`). The engine recognises the
/// face, adds it on a miss and files the conversation; the answer is shown
/// here, spoken, and sent to the lens.
///
/// It is built to be glanced at. The Meet button floats in glass at the bottom
/// with the two switches a wearer reaches for beside it, the way Camera sets
/// its controls around the shutter. Above it is the one thing happening now:
/// what is being heard, or the latest person, set as Contacts sets a card.
/// Everything else is one tap away in the toolbar menu.
struct MeetView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @EnvironmentObject private var speech: SpeechManager
    @ObservedObject private var engine = MeetEngine.shared
    @ObservedObject private var dictation = DictationManager.shared
    @ObservedObject private var audio = AudioSessionController.shared
    @AppStorage("usePhoneCamera") private var usePhoneCamera = false
    @AppStorage(WelcomeView.seenKey) private var hasSeenWelcome = false
    @State private var tool: ManualTool?
    @State private var renaming: NameTarget?
    @Namespace private var controls

    /// The two halves of Meet on their own, for when one needs isolating.
    enum ManualTool: String, Identifiable {
        case capture, listen
        var id: String { rawValue }
    }

    /// Newest first. The engine does not keep its results in time order.
    private var results: [MeetResult] {
        engine.results.sorted { $0.date > $1.date }
    }

    /// Where the photo will come from, under the title.
    private var sourceLine: String {
        glasses.isConnected && !usePhoneCamera ? "Using your glasses" : "Using the iPhone camera"
    }

    /// Nothing has happened yet. The page then explains itself, or says what
    /// is stopping it, instead of showing an empty list.
    private var isEmpty: Bool {
        results.isEmpty && engine.phase == .idle && engine.errorText == nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if !dictation.isUsable {
            ContentUnavailableView {
                Label("Thread Can't Listen", systemImage: "mic.slash")
            } description: {
                Text("Meet needs the microphone and speech recognition to hear introductions. Allow both in Settings.")
            } actions: {
                OpenSettingsButton()
                    .buttonStyle(.glass)
            }
        } else if glasses.cameraBlocked {
            ContentUnavailableView {
                Label("Camera Is Off", systemImage: "camera.badge.ellipsis")
            } description: {
                Text("Meet still saves what is said, but it can't match or add a face without the camera.")
            } actions: {
                OpenSettingsButton()
                    .buttonStyle(.glass)
            }
        } else {
            ContentUnavailableView {
                Label("Meet Someone", systemImage: "person.wave.2")
            } description: {
                Text("Press Meet, or the capture button on your glasses, and let them introduce themselves. Thread takes one photo and listens until you press again.")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                problemsSection
                soundOutputSection
                switch engine.phase {
                case .listening: listeningSection
                case .thinking: thinkingSection
                case .idle: EmptyView()
                }
                if let latest = results.first {
                    MeetResultSections(result: latest, onRename: { renaming = NameTarget(name: $0) })
                }
                if results.count > 1 {
                    Section("Earlier") {
                        ForEach(results.dropFirst()) { result in
                            NavigationLink {
                                MeetResultDetail(result: result)
                            } label: {
                                MeetResultRow(result: result)
                            }
                        }
                    }
                }
            }
            .overlay {
                if isEmpty {
                    emptyState
                }
            }
            .safeAreaBar(edge: .bottom) {
                controlsBar
                    .padding(.bottom, 12)
            }
            .navigationTitle("Meet")
            .navigationSubtitle(sourceLine)
            .toolbar { toolbarMenu }
            .sheet(item: $tool) { tool in
                ManualToolSheet(tool: tool)
                    .environmentObject(glasses)
                    .environmentObject(speech)
            }
            .sheet(item: $renaming) { target in
                RenameSheet(placeholder: target.name, onDone: {})
            }
            .animation(.snappy(duration: 0.25), value: engine.phase)
            .animation(.snappy(duration: 0.25), value: engine.results.count)
        }
        .onAppear {
            engine.bind(glasses: glasses, speech: speech)
            // Until the welcome sheet is closed, the microphone stays shut, so
            // its permission prompt does not land on top of the sheet.
            if hasSeenWelcome { DictationManager.shared.prime() }
            glasses.refreshCameraAuth()
        }
    }

    // MARK: Controls

    /// The Meet button, with Speak and Keep Going on either side of it, in one
    /// glass container so they read as one set of controls.
    private var controlsBar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                Button {
                    speech.speakAloud.toggle()
                } label: {
                    Image(systemName: speech.speakAloud ? "speaker.wave.2.fill" : "speaker.slash")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Speak the card")
                .accessibilityValue(speech.speakAloud ? "On" : "Off")

                meetButton

                Button {
                    engine.autoRepeat.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(engine.autoRepeat ? Color.white : Color.primary)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    engine.autoRepeat ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                    in: .circle
                )
                .accessibilityLabel("Keep going")
                .accessibilityValue(engine.autoRepeat ? "On" : "Off")
                .accessibilityHint("Repeats Meet until you turn it off")
            }
            .font(.title3)
        }
        .sensoryFeedback(.selection, trigger: speech.speakAloud)
        .sensoryFeedback(.selection, trigger: engine.autoRepeat)
    }

    /// One control for the whole turn: it starts a pass, and while the app is
    /// listening it ends the turn, so nobody waits for a silence they can't
    /// produce.
    private var meetButton: some View {
        Button {
            if engine.phase == .listening {
                engine.finishListening()
            } else {
                Task { await engine.runOnce() }
            }
        } label: {
            HStack(spacing: 8) {
                switch engine.phase {
                case .idle:
                    Image(systemName: "person.wave.2.fill")
                    Text("Meet")
                case .listening:
                    Image(systemName: "stop.fill")
                    Text("Done")
                case .thinking:
                    ProgressView()
                        .tint(.white)
                    Text("Looking Up")
                }
            }
            .font(.title3.weight(.semibold))
            .frame(minWidth: 148, minHeight: 40)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(engine.phase == .listening ? .red : .accentColor)
        .disabled(engine.phase == .thinking)
        .glassEffectID("meet", in: controls)
        .accessibilityHint(
            engine.phase == .listening
                ? "Stops listening and looks them up"
                : "Takes a photo and listens, then looks them up or adds them"
        )
    }

    /// Shown while the glasses are connected but cards would play on the
    /// iPhone's own speaker, with the picker to send them to the glasses.
    @ViewBuilder
    private var soundOutputSection: some View {
        if glasses.isConnected, speech.speakAloud, !audio.outputIsBluetooth {
            Section {
                HStack(spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cards are playing on the iPhone")
                            Text("Tap the button and choose your glasses.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                    SoundOutputPicker()
                        .frame(width: 36, height: 36)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            SoundOutputPicker()
                .frame(width: 28, height: 28)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section {
                    Button("Photo Only", systemImage: "camera") { tool = .capture }
                    Button("Listen Only", systemImage: "waveform") { tool = .listen }
                }
                Section {
                    Picker(selection: $engine.trailingSilence) {
                        Text("When I Press Again").tag(0.0)
                        ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { seconds in
                            Text("After " + seconds.formatted(.number.precision(.fractionLength(1))) + " Seconds of Quiet")
                                .tag(seconds)
                        }
                    } label: {
                        Label("Stop Listening", systemImage: "timer")
                        Text(
                            engine.stopsOnPress
                                ? "When you press again"
                                : "After " + engine.trailingSilence.formatted(.number.precision(.fractionLength(1))) + " seconds of quiet"
                        )
                    }
                    .pickerStyle(.menu)
                }
                if !engine.results.isEmpty {
                    Section {
                        Button("Clear Results", systemImage: "trash", role: .destructive) {
                            engine.clearResults()
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Listening

    private var listeningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Listening", systemImage: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                    Text(dictation.captureElapsed.clockText)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(dictation.transcript.isEmpty ? "Let them introduce themselves." : dictation.transcript)
                    .font(.title3)
                    .foregroundStyle(dictation.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                LevelMeter(level: dictation.level)
                    .foregroundStyle(.red.opacity(0.85))
                Text(dictation.turnStateLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var thinkingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(engine.statusLine.isEmpty ? "Matching against your network…" : engine.statusLine)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Problems

    @ViewBuilder
    private var problemsSection: some View {
        // A dictation error while it cannot listen at all is the same fact
        // as the row below it, so only one of them is shown. The engine's
        // error is already the latest result when that result is a problem.
        let engineError = results.first?.isProblem == true ? nil : engine.errorText
        let error = engineError ?? (dictation.isUsable ? dictation.errorText : nil)
        // With nothing else on the page, the empty state says it instead.
        if !isEmpty, error != nil || !dictation.isUsable || glasses.cameraBlocked {
            Section {
                if let error {
                    ProblemLabel(error)
                }
                if !dictation.isUsable {
                    ProblemLabel("Thread can't listen. Allow the microphone and speech recognition in Settings.")
                }
                if glasses.cameraBlocked {
                    ProblemLabel("The camera is off for Thread. Meet still saves what is said, but can't match or add a face.")
                }
                if !dictation.isUsable || glasses.cameraBlocked {
                    OpenSettingsButton()
                }
            }
        }
    }
}

/// Photo Only or Listen Only, in a sheet over Meet.
private struct ManualToolSheet: View {
    let tool: MeetView.ManualTool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch tool {
                case .capture: CaptureView()
                case .listen: ListenView()
                }
            }
            .navigationTitle(tool == .capture ? "Photo Only" : "Listen Only")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
    }
}

/// A person's name, for `.sheet(item:)`.
struct NameTarget: Identifiable {
    let name: String
    var id: String { name }
}

// MARK: - Results

/// One result as a row, for the list of earlier ones.
struct MeetResultRow: View {
    let result: MeetResult

    var body: some View {
        if result.isProblem {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                    Text(result.date, style: .time)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            PersonRow(
                name: result.name,
                subtitle: result.subhead.isEmpty ? result.badge : result.subhead,
                trailing: result.date.formatted(date: .omitted, time: .shortened)
            )
        }
    }
}

/// One result in full, as Contacts would show it: the person at the top, then
/// what to say next, what is owed, and what the answer was built from.
struct MeetResultSections: View {
    let result: MeetResult
    /// Offered for a person Thread named itself, to give them a real name.
    var onRename: ((String) -> Void)?

    /// When it happened and what it used, as a sentence.
    private var provenance: String {
        var parts = [result.date.formatted(date: .omitted, time: .shortened)]
        if !result.frameSource.isEmpty { parts.append("photo from the \(result.frameSource)") }
        if !result.micSource.isEmpty { parts.append("heard by the \(result.micSource)") }
        return parts.joined(separator: ", ") + "."
    }

    /// What kind of meeting this was, in the words Contacts would use.
    private var caption: String {
        switch result.kind {
        case .recognised: return "You've met before"
        case .newFace: return "New contact"
        case .merged: return "Face added to their contact"
        case .renamed: return "Was “\(result.renamedFrom)”"
        case .guidance, .failed: return ""
        }
    }

    var body: some View {
        Section {
            if result.isProblem {
                problemHeader
            } else {
                VStack(spacing: 16) {
                    PersonHeader(name: result.name, subtitle: result.subhead, caption: caption)
                    if result.placeholder, let onRename, FaceCache.frame(for: result.name) != nil {
                        Button("Add Their Name", systemImage: "pencil") { onRename(result.name) }
                            .buttonStyle(.glass)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

        if !result.lines.isEmpty {
            // For a person these are things to say; for a problem, what
            // happened and what to do.
            Section {
                ForEach(Array(result.lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 && !result.isProblem ? .title3 : .body)
                        .padding(.vertical, index == 0 && !result.isProblem ? 4 : 0)
                }
            } header: {
                if !result.isProblem {
                    Text("Say Next")
                }
            }
        }

        if !result.followups.isEmpty {
            Section("You Owe Them") {
                ForEach(Array(result.followups.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "arrow.uturn.forward")
                }
            }
        }

        Section {
            if !result.topics.isEmpty {
                LabeledContent("Talked About") {
                    Text(result.topics.joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
            }
            if !result.transcript.isEmpty {
                DisclosureGroup("What They Said") {
                    Text(result.transcript)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(provenance)
        }
    }

    private var problemHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: result.kind == .failed ? "wifi.exclamationmark" : "camera.metering.unknown")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(result.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if !result.headline.isEmpty {
                Text(result.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// An earlier result, opened from the list.
struct MeetResultDetail: View {
    let result: MeetResult
    @State private var renaming: NameTarget?

    var body: some View {
        List {
            MeetResultSections(result: result, onRename: { renaming = NameTarget(name: $0) })
        }
        .navigationTitle(result.isProblem ? result.badge : result.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renaming) { target in
            RenameSheet(placeholder: target.name, onDone: {})
        }
    }
}

// MARK: - Bottom accessory

/// A Meet pass seen from another tab: a line above the tab bar, the way Music
/// shows what is playing, with Done to end the turn from anywhere.
struct MeetAccessory: View {
    @ObservedObject private var engine = MeetEngine.shared
    @ObservedObject private var dictation = DictationManager.shared
    var onOpen: () -> Void

    private var title: String {
        switch engine.phase {
        case .listening: return "Listening"
        case .thinking: return "Looking Up"
        case .idle: return "Keep Going Is On"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: engine.phase == .idle ? "repeat" : "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: engine.phase == .listening)
                        .foregroundStyle(engine.phase == .listening ? Color.red : Color.accentColor)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if engine.phase == .listening {
                        Text(dictation.captureElapsed.clockText)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Meet")

            if engine.phase == .thinking {
                ProgressView()
            }
            // Keep Going is stopped from here too, not only between passes.
            if engine.autoRepeat {
                Button("Stop") {
                    engine.autoRepeat = false
                    engine.finishListening()
                }
                .font(.subheadline.weight(.semibold))
            } else if engine.phase == .listening {
                Button("Done") { engine.finishListening() }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
    }
}
