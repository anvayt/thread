import AVFoundation
import Combine
import Foundation
import Speech

/// Every number that decides how long Thread listens for. All of it lives here
/// so it can be tuned in one place between demo runs.
///
/// The rule these encode: a capture ends when the *person* stops talking, not
/// when a timer expires. A fixed window is wrong in both directions — it cuts a
/// long introduction in half and it makes a two-word "hi, I'm Sam" wait around.
enum TurnTiming {
    /// Trailing quiet that ends a turn, once anything at all has been heard.
    static let trailingSilence: Double = 2.0
    /// A capture never ends before this, so a beat of hesitation at the start
    /// isn't mistaken for the end of the sentence.
    static let hardFloor: Double = 3.0
    /// A capture never runs past this, whatever the room sounds like.
    static let hardCeiling: Double = 45.0
    /// If literally nothing is heard, give up here rather than at the ceiling.
    static let silentStartTimeout: Double = 9.0
    /// When a turn ends only on a press, it still never runs past this, so a
    /// forgotten press cannot leave the microphone open indefinitely.
    static let pressCeiling: Double = 180.0
    /// Level (0…1, as reported by the input tap) below which a buffer counts as
    /// silence. The floor of the adaptive gate.
    static let voiceFloor: Double = 0.075
    /// The gate sits this far above the measured room noise.
    static let noiseGateMultiple: Double = 2.5
    /// How often the turn loop re-evaluates.
    static let tick: Double = 0.1
}

/// Live speech-to-text over SFSpeechRecognizer + AVAudioEngine.
///
/// This is a single shared instance because the audio engine and its input tap
/// are process-wide resources. Two DictationManagers (one per tab) would fight
/// over `inputNode`, which is what made the mic look broken.
///
/// Design rules, all of which exist because of an on-stage failure:
///  * the audio session is owned by `AudioSessionController` and is NEVER
///    deactivated here — a photo capture or a TTS line no longer kills the mic.
///  * the engine is started and the tap installed ONCE (`prime()`); start/stop
///    only create and finish the recognition *task*. Stopping does not touch
///    the engine, so the next capture starts instantly.
///  * on-device recognition is preferred when the device supports it, so bad
///    conference Wi-Fi cannot break transcription. If the on-device task fails
///    immediately we retry once over the network.
///  * SFSpeechRecognizer drops an audio-buffer task after ~1 minute; a watchdog
///    rolls the task over at 50s and keeps the text captured so far.
///  * authorization state is published so a denied permission is visible in the
///    UI instead of failing silently.
/// Thread-safe handle on the live recognition request.
///
/// The input tap fires on a realtime audio thread and the buffer it hands over
/// is only valid for the duration of that callback — hopping to the main actor
/// before calling `append` loses audio. So the tap appends synchronously
/// through this box, which is the only piece of state shared with the audio
/// thread. `GlassesEar` uses a second one for audio arriving from the glasses.
final class RecognitionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var accepting = false
    private var muted = false

    func open(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.request = request
        accepting = true
        lock.unlock()
    }

    func close() {
        lock.lock()
        accepting = false
        request = nil
        lock.unlock()
    }

    /// Drops audio while TTS is talking so Thread never transcribes itself.
    func setMuted(_ value: Bool) {
        lock.lock()
        muted = value
        lock.unlock()
    }

    /// True while Thread is speaking, when nothing the mic hears is wanted.
    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        let target = (accepting && !muted) ? request : nil
        lock.unlock()
        target?.append(buffer)
        return target != nil
    }
}

/// The last few seconds the phone's microphone heard, kept in memory only and
/// overwritten as new audio arrives, so a name said just before the wearer
/// presses still reaches the transcript ("Include the Moment Before").
///
/// Filled from the microphone tap, on the audio thread, only while no turn is
/// listening and Thread is not speaking. Nothing here is saved or sent: a
/// Meet takes it with `drain()` and everything else is overwritten.
final class RecentAudio: @unchecked Sendable {
    /// UserDefaults key for Include the Moment Before: seconds, 0 for off.
    static let secondsKey = "momentBeforeSeconds"

    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var seconds: Double = 0
    private var capacity: Double = 0

    /// How many seconds to keep. 0 turns it off and empties it.
    func setCapacity(_ value: Double) {
        lock.lock()
        capacity = max(0, value)
        if capacity == 0 {
            buffers.removeAll()
            seconds = 0
        }
        lock.unlock()
    }

    /// Copies the buffer in: the tap's buffer is only valid inside its call.
    func add(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let keep = capacity
        lock.unlock()
        guard keep > 0, let copy = Self.copy(buffer) else { return }
        let length = Double(copy.frameLength) / copy.format.sampleRate
        lock.lock()
        buffers.append(copy)
        seconds += length
        while seconds > keep, let first = buffers.first {
            seconds -= Double(first.frameLength) / first.format.sampleRate
            buffers.removeFirst()
        }
        lock.unlock()
    }

    /// Hands over what is kept, oldest first, and empties it.
    func drain() -> (buffers: [AVAudioPCMBuffer], seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let taken = (buffers, seconds)
        buffers = []
        seconds = 0
        return taken
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let from = buffer.floatChannelData, let to = copy.floatChannelData {
            let count = buffer.format.isInterleaved ? frames * channels : frames
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                to[channel].update(from: from[channel], count: count)
            }
        } else if let from = buffer.int16ChannelData, let to = copy.int16ChannelData {
            let count = buffer.format.isInterleaved ? frames * channels : frames
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                to[channel].update(from: from[channel], count: count)
            }
        } else {
            return nil
        }
        return copy
    }
}

@MainActor
final class DictationManager: ObservableObject {
    static let shared = DictationManager()

    // MARK: Published state

    /// Everything heard this session: finished segments + the live partial.
    @Published private(set) var transcript = ""
    /// Just the current recognition task's partial, for the "live" line.
    @Published private(set) var partial = ""
    @Published private(set) var isRecording = false
    @Published private(set) var errorText: String?
    /// Rough input level 0…1, for the pulsing mic and the level meter.
    @Published private(set) var level: Double = 0
    /// True once this turn has heard actual speech — the trailing-silence timer
    /// is meaningless before it flips.
    @Published private(set) var heardSpeech = false
    /// True while the level is above the gate right now.
    @Published private(set) var voiceActive = false
    /// Seconds of quiet still owed before the turn ends. Counts down on screen.
    @Published private(set) var silenceRemaining: Double = TurnTiming.trailingSilence
    /// How long this turn has been running.
    @Published private(set) var captureElapsed: Double = 0
    /// Why the last turn ended, in words, for the status line and the log.
    @Published private(set) var endReason = ""
    /// True during a turn that only a press can end.
    @Published private(set) var waitsForPress = false
    /// Names Thread already knows: the wearer's, and the people and companies
    /// in the network. Given to the recogniser as hints, so a name it has
    /// heard before comes out spelled the same way. Apple allows 100.
    private(set) var hintNames: [String] = []
    /// Non-nil once permissions have been asked for at launch.
    @Published private(set) var speechAuth: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published private(set) var micGranted = false
    @Published private(set) var engineRunning = false
    /// Free-text diagnostic shown in Glasses › Diagnostics.
    @Published private(set) var diagnostic = "mic: not started"

    // MARK: Internals

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let sink = RecognitionSink()
    /// The seconds before a Meet, when Include the Moment Before is on.
    let recent = RecentAudio()
    private var muteObserver: AnyCancellable?
    private var tapInstalled = false
    private var committed = ""
    private var taskStartedAt: Date?
    private var watchdog: Task<Void, Never>?
    private var routeObserver: AnyCancellable?
    /// Set when we are rolling the task over at the 1-minute limit, so the
    /// completion handler doesn't treat it as a user-visible failure.
    private var rollingOver = false
    private var usedOnDeviceForThisTask = false
    private var retriedOnNetwork = false
    /// Last moment the input was above the gate. The end-of-turn detector is
    /// nothing more than "how long ago was this".
    private var lastVoiceAt = Date()
    /// Running estimate of the room, adapted only while it is quiet so a talker
    /// can never raise the gate above their own voice.
    private var noiseFloor: Double = 0

    /// Identifies the recognition task whose results are allowed to touch the
    /// text. Bumped every time a task is created or torn down.
    ///
    /// This is the guard that makes the transcript append-only. A finished task
    /// keeps delivering for a while after `finish()` — over the network on bad
    /// Wi-Fi that can be seconds — and its `bestTranscription` is cumulative
    /// *for that task only*. Without an epoch check, that late delivery
    /// assigned an old, already-committed string over `partial` and the live
    /// text on screen was replaced by a stale one: the "it was there and then
    /// it got overwritten" report. Results from any epoch but the current one
    /// are now dropped.
    private var epoch = 0

    private init() {
        routeObserver = AudioSessionController.shared.$routeGeneration
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.rebuildEngineAfterRouteChange() }
            }
        // Mirror the TTS flag into the audio-thread-safe sink.
        muteObserver = AudioSessionController.shared.$isSpeaking
            .sink { [sink] speaking in sink.setMuted(speaking) }
        recent.setCapacity(UserDefaults.standard.double(forKey: RecentAudio.secondsKey))
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// One line describing whether the mic pipeline is actually usable.
    var authSummary: String {
        var bits: [String] = []
        switch speechAuth {
        case .authorized: bits.append("speech: allowed")
        case .denied: bits.append("speech: DENIED — enable in Settings › Thread")
        case .restricted: bits.append("speech: restricted on this device")
        case .notDetermined: bits.append("speech: not asked yet")
        @unknown default: bits.append("speech: unknown")
        }
        bits.append(micGranted ? "mic: allowed" : "mic: DENIED — enable in Settings › Thread")
        bits.append(isAvailable ? "recognizer: available" : "recognizer: unavailable")
        if supportsOnDevice { bits.append("on-device: yes") }
        return bits.joined(separator: " · ")
    }

    var isUsable: Bool {
        speechAuth == .authorized && micGranted && isAvailable
    }

    // MARK: Permissions — asked once, at launch

    /// Requests speech + microphone authorization and records the outcome.
    /// Called from the app's launch path so a denial is visible immediately
    /// rather than the first time the user holds the button on stage.
    func requestAuthorization() async {
        #if DEBUG
        // With `-noAudio YES` nothing will listen, so do not put up the
        // permission prompts either; an unattended run cannot answer them.
        if UserDefaults.standard.bool(forKey: "noAudio") { return }
        #endif
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        speechAuth = speech

        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        micGranted = mic

        diagnostic = authSummary
        print("[thread] \(diagnostic)")
    }

    // MARK: Engine lifecycle

    /// Rebuilds `hintNames` from Your Name and the people in the network.
    /// Called at launch, after each Meet and when Your Name changes.
    func refreshHintNames() async {
        var names: [String] = []
        let wearer = BackendAPI.wearerName
        if !wearer.isEmpty { names.append(wearer) }
        if let people = try? await BackendAPI.roster() {
            for person in people where !FaceCache.isPlaceholder(person.name) {
                names.append(person.name)
                if let first = person.name.split(separator: " ").first, first.count > 1 {
                    names.append(String(first))
                }
                if !person.org.isEmpty { names.append(person.org) }
            }
        }
        var seen = Set<String>()
        hintNames = Array(names.filter { seen.insert($0.lowercased()).inserted }.prefix(100))
        print("[thread] recogniser hints: \(hintNames.count) names")
    }

    /// Starts the audio engine and installs the input tap. Idempotent — the
    /// tap is installed exactly once and survives photo captures, TTS and tab
    /// switches.
    @discardableResult
    func prime() -> Bool {
        #if DEBUG
        // A simulator with no audio input aborts inside AVAudioEngine, which
        // nothing here can catch. Launching with `-noAudio YES` leaves the
        // engine alone; `setTranscript` stands in for the microphone.
        if UserDefaults.standard.bool(forKey: "noAudio") {
            diagnostic = "mic: switched off by -noAudio"
            return false
        }
        #endif
        guard !engine.isRunning else {
            engineRunning = true
            return true
        }
        guard AudioSessionController.shared.isActive
            || AudioSessionController.shared.activate()
        else {
            errorText = "The audio session wouldn't start. Restart the app."
            return false
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorText = "The microphone isn't ready. Disconnect any audio device, reconnect it and try again."
            diagnostic = "mic: invalid input format (\(format.sampleRate) Hz)"
            return false
        }

        if !tapInstalled {
            let sink = self.sink
            let recent = self.recent
            input.installTap(onBus: 0, bufferSize: 1024, format: format) {
                [weak self] buffer, _ in
                // The tap is permanent and appends on THIS thread — the buffer
                // is not valid past the callback. Only the UI level hops to the
                // main actor.
                let live = sink.append(buffer)
                // Between turns, keep the last few seconds for the next Meet,
                // unless that is Thread's own voice.
                if !live, !sink.isMuted { recent.add(buffer) }
                let peak = Self.peak(of: buffer)
                // One audio path, two consumers: the recognizer gets the
                // samples, the main actor gets the level — which is also the
                // whole of the end-of-turn detector. No second tap, no second
                // engine.
                Task { @MainActor in self?.observe(level: peak, live: live) }
            }
            tapInstalled = true
        }

        do {
            engine.prepare()
            try engine.start()
            engineRunning = true
            // The sample rate is the tell: the phone mic runs at 44.1/48 kHz,
            // a Bluetooth headset mic drags the whole route down to 8 kHz HFP.
            let source = AudioSessionController.shared.inputIsPhoneMic
                ? "phone mic" : "EXTERNAL MIC — expect poor transcription"
            diagnostic = "mic: engine running @ \(Int(format.sampleRate)) Hz · "
                + "\(source) · \(AudioSessionController.shared.routeDescription)"
            print("[thread] \(diagnostic)")
            return true
        } catch {
            engineRunning = false
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            diagnostic = "mic: engine failed — \(error.localizedDescription)"
            return false
        }
    }

    /// Full teardown. Only used when leaving the app; the demo never calls it.
    func shutdown() {
        stopTask()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engineRunning = false
        diagnostic = "mic: stopped"
    }

    private func rebuildEngineAfterRouteChange() {
        // A route change invalidates the input node's format; the tap has to be
        // reinstalled or buffers stop arriving (this is what happened when the
        // glasses connected mid-session).
        let wasRecording = isRecording
        let carried = transcript
        stopTask()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engineRunning = false
        AudioSessionController.shared.reassert()
        guard prime() else { return }
        if wasRecording {
            // `carried` already includes the partial, so clear it first or
            // beginTask()'s commit would count that text twice.
            partial = ""
            committed = carried
            beginTask()
        }
    }

    // MARK: Control

    /// Begin (or resume) capturing. Keeps whatever was already transcribed if
    /// `keepExisting` is true — used when a capture appends to a session.
    func start(keepExisting: Bool = false, includeMomentBefore: Bool = false) async {
        guard !isRecording else { return }
        errorText = nil
        if !keepExisting {
            committed = ""
            transcript = ""
            partial = ""
        }

        if speechAuth == .notDetermined || !micGranted {
            await requestAuthorization()
        }
        guard speechAuth == .authorized else {
            errorText = "Speech recognition is off for Thread. Turn it on in Settings."
            return
        }
        guard micGranted else {
            errorText = "The microphone is off for Thread. Turn it on in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorText = "Speech recognition isn't available right now (no network and no on-device model)."
            return
        }
        guard prime() else { return }

        retriedOnNetwork = false
        beginTask(includeMomentBefore: includeMomentBefore)
    }

    /// Creates a fresh recognition request + task against the already-running
    /// engine. Used by `start()` and by the 1-minute rollover.
    private func beginTask(forceNetwork: Bool = false, includeMomentBefore: Bool = false) {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = hintNames
        // What was said just before the press goes in first, then live audio.
        // A turn that does not ask for it discards it, so it never reaches a
        // later one.
        let before = recent.drain()
        if includeMomentBefore, !before.buffers.isEmpty {
            before.buffers.forEach(request.append)
            print(String(format: "[thread] included %.1f s from before the press", before.seconds))
        }
        let onDevice = !forceNetwork && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        usedOnDeviceForThisTask = onDevice
        self.request = request
        sink.open(request)

        // Whatever the previous task produced becomes a finished segment here,
        // and ONLY here. Committing anywhere else double-counts, because a
        // recognition task's `bestTranscription` is cumulative and a final
        // result can land after stop() and re-populate `partial`.
        commitPartial()

        isRecording = true
        taskStartedAt = Date()
        partial = ""
        diagnostic = "mic: listening (\(onDevice ? "on-device" : "network"))"

        // Only this task may write the text from here on. A rollover or a stop
        // bumps the epoch, which retires every result still in flight from the
        // task being replaced.
        epoch += 1
        let myEpoch = epoch

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error
            Task { @MainActor in
                guard let self, self.epoch == myEpoch else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Assigning is right: `text` is this task's whole output so
                    // far, and everything from earlier tasks already sits in
                    // `committed`. An empty result never lands, so a recognizer
                    // hiccup can't blank the line the user is watching.
                    self.partial = text
                    self.recomputeTranscript()
                }
                if failure != nil || isFinal {
                    self.handleTaskEnd(error: failure, isFinal: isFinal)
                }
            }
        }

        startWatchdog()
    }

    private func handleTaskEnd(error: Error?, isFinal: Bool) {
        // A rollover ends the old task on purpose — not an error.
        if rollingOver { return }

        if let error {
            let detail = error as NSError
            print(
                "[thread] speech recognition failed (\(usedOnDeviceForThisTask ? "on-device" : "network")): "
                    + "\(detail.domain) \(detail.code), \(detail.localizedDescription)"
            )
        }
        if let error, isRecording, partial.isEmpty, transcript.isEmpty {
            // On-device model missing/failing is common on a fresh device;
            // fall back to the network recognizer once before giving up.
            if usedOnDeviceForThisTask, !retriedOnNetwork {
                retriedOnNetwork = true
                diagnostic = "mic: on-device failed, retrying over network"
                task = nil
                request = nil
                beginTask(forceNetwork: true)
                return
            }
            errorText = Self.missingInSimulator(error)
                ? "Speech recognition doesn't run in the Simulator. To type the words instead, open More › Listen Only and tap the keyboard button."
                : "Didn't catch that. \(error.localizedDescription)"
            diagnostic = "mic: recognition error — \(error.localizedDescription)"
        }

        // Deliberately no commit here: `partial` already holds the whole of this
        // task's text, and it stays there until the next task starts. A final
        // result arriving after stop() just refines it in place.
        if !isRecording {
            request = nil
            task = nil
        }
    }

    /// Apple's speech model is a download that the iOS Simulator does not
    /// have, so there both recognisers fail to start with this error, and no
    /// setting changes that. Anywhere else the error is reported as it comes.
    private static func missingInSimulator(_ error: Error) -> Bool {
        #if targetEnvironment(simulator)
        let detail = error as NSError
        return detail.domain == "kLSRErrorDomain" && detail.code == 300
        #else
        return false
        #endif
    }

    /// Stops the recognition task and returns the final transcript. The engine,
    /// the tap and the audio session are all left alone on purpose.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return transcript }
        isRecording = false
        level = 0
        voiceActive = false
        watchdog?.cancel()
        watchdog = nil
        sink.close()
        request?.endAudio()
        task?.finish()
        // `partial` is left intact so the final result can refine it; the next
        // beginTask() is what turns it into a committed segment.
        taskStartedAt = nil
        diagnostic = "mic: idle (engine still running)"
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopTask() {
        isRecording = false
        watchdog?.cancel()
        watchdog = nil
        sink.close()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        level = 0
        voiceActive = false
        // Hard teardown: nothing this task still delivers may touch the text.
        epoch += 1
    }

    // MARK: End of turn

    /// The level a buffer has to clear to count as speech: a fixed floor, lifted
    /// above whatever the room is doing.
    var voiceGate: Double {
        max(TurnTiming.voiceFloor, noiseFloor * TurnTiming.noiseGateMultiple)
    }

    /// Called for every input buffer, on the main actor. Publishes the level and
    /// maintains the two facts the turn loop reads: has anyone spoken, and when.
    private func observe(level value: Double, live: Bool) {
        let heard = live ? value : 0
        level = heard
        guard live, isRecording else {
            if voiceActive { voiceActive = false }
            return
        }
        if heard >= voiceGate {
            lastVoiceAt = Date()
            heardSpeech = true
            if !voiceActive { voiceActive = true }
        } else {
            if voiceActive { voiceActive = false }
            // Adapt the floor only during quiet; 47 buffers a second means this
            // settles on the room in well under a second.
            noiseFloor = noiseFloor * 0.97 + heard * 0.03
        }
    }

    /// One line describing what the capture is doing right now, for the UI.
    var turnStateLine: String {
        guard isRecording else { return endReason.isEmpty ? "Ready." : "Ended: \(endReason)." }
        if waitsForPress { return "Press the capture button or Done when they've finished." }
        if !heardSpeech { return "Listening…" }
        if voiceActive { return "They're still talking" }
        return String(format: "Wrapping up… %.1f s", silenceRemaining)
    }

    /// Record until the person actually stops talking.
    ///
    /// Replaces the fixed window that was cutting long introductions in half and
    /// making short ones wait. The turn ends on `trailingSilence` seconds of
    /// quiet after any speech, and is bounded at both ends: never shorter than
    /// `floor` (an early pause is not the end of a sentence) and never longer
    /// than `ceiling` (nothing hangs on stage). A `stop()` from anywhere — the
    /// Done button — ends it immediately.
    ///
    /// Two independent activity signals feed it, so a mis-tuned gate cannot
    /// strand the capture: the level from the audio tap, and new words arriving
    /// from the recognizer.
    ///
    /// `alsoHeard` is a third: the length of what a second listener (the
    /// glasses) has transcribed so far. While that grows the turn stays open,
    /// so a phone that hears little from a pocket does not end it early.
    /// With `endsOnSilence` false, quiet never ends the turn: only `stop()`
    /// (the Done button, or a press on the glasses) or the ceiling does.
    func recordUntilSilence(
        trailingSilence: Double = TurnTiming.trailingSilence,
        floor: Double = TurnTiming.hardFloor,
        ceiling: Double = TurnTiming.hardCeiling,
        endsOnSilence: Bool = true,
        keepExisting: Bool = false,
        includeMomentBefore: Bool = false,
        alsoHeard: (@MainActor () -> Int)? = nil
    ) async -> String {
        waitsForPress = !endsOnSilence
        heardSpeech = false
        voiceActive = false
        noiseFloor = 0
        captureElapsed = 0
        silenceRemaining = trailingSilence
        endReason = ""

        await start(keepExisting: keepExisting, includeMomentBefore: includeMomentBefore)
        guard isRecording else { return "" }

        let began = Date()
        lastVoiceAt = began
        var lastLength = transcript.count
        var lastAlsoHeard = alsoHeard?() ?? 0
        var reason = "the \(Int(ceiling))s ceiling"

        while isRecording {
            try? await Task.sleep(for: .seconds(TurnTiming.tick))
            let now = Date()
            captureElapsed = now.timeIntervalSince(began)

            // Words landing from the recognizer are activity too — this is the
            // backstop for a talker quieter than the gate.
            if transcript.count > lastLength {
                lastLength = transcript.count
                lastVoiceAt = now
                heardSpeech = true
            }
            if let alsoHeard {
                let length = alsoHeard()
                if length > lastAlsoHeard {
                    lastAlsoHeard = length
                    lastVoiceAt = now
                    heardSpeech = true
                }
            }

            let silence = now.timeIntervalSince(lastVoiceAt)
            silenceRemaining = heardSpeech
                ? max(0, trailingSilence - silence)
                : trailingSilence

            if captureElapsed >= ceiling { break }
            if !endsOnSilence { continue }
            if !heardSpeech, captureElapsed >= TurnTiming.silentStartTimeout {
                reason = "nobody spoke"
                break
            }
            if heardSpeech, captureElapsed >= floor, silence >= trailingSilence {
                reason = String(format: "%.1fs of silence", trailingSilence)
                break
            }
        }

        // Every break above leaves the recorder running; the only way it can be
        // stopped already is somebody tapping Done.
        let stoppedByHand = !isRecording
        waitsForPress = false
        stop()
        endReason = stoppedByHand ? "you tapped Done" : reason
        print(
            "[thread] turn ended after \(String(format: "%.1f", captureElapsed))s — \(endReason)"
        )
        silenceRemaining = 0
        voiceActive = false
        // The recognizer keeps refining for a beat after endAudio(); give it a
        // short grace window so the last few words make it in.
        try? await Task.sleep(for: .milliseconds(700))
        return seal()
    }

    /// Record for a fixed window and hand back what was said. Kept for the
    /// Capture/Listen paths that want a bounded clip; Meet uses
    /// `recordUntilSilence` instead.
    func record(seconds: Double, keepExisting: Bool = false) async -> String {
        await start(keepExisting: keepExisting)
        guard isRecording else { return "" }
        let deadline = Date().addingTimeInterval(seconds)
        while isRecording, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        stop()
        // The recognizer keeps refining for a beat after endAudio(); give it a
        // short grace window so the last few words make it in.
        try? await Task.sleep(for: .milliseconds(700))
        return seal()
    }

    /// Freeze what was heard.
    ///
    /// The grace window is over, so the live partial becomes committed text and
    /// every result still in flight is retired. After this the string cannot
    /// change until the next capture starts — which is what makes "the text you
    /// watched appear is exactly the text that gets posted" true rather than
    /// merely likely.
    @discardableResult
    func seal() -> String {
        epoch += 1
        commitPartial()
        let text = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        committed = text
        recomputeTranscript()
        print("[thread] transcript sealed (\(text.count) chars): \"\(text)\"")
        return text
    }

    func reset() {
        epoch += 1
        committed = ""
        partial = ""
        transcript = ""
        errorText = nil
    }

    /// Lets the demo run in the simulator, or after a mic mishap, by typing.
    func setTranscript(_ text: String) {
        // Retire anything in flight, or a late result would overwrite what was
        // just typed in.
        epoch += 1
        committed = text
        partial = ""
        recomputeTranscript()
    }

    // MARK: 1-minute limit

    /// SFSpeechRecognizer abandons a buffer-fed task at roughly 60 seconds.
    /// Roll it over at 50 so a long conversation keeps transcribing.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while let self, self.isRecording {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isRecording,
                    let started = self.taskStartedAt
                else { continue }
                if Date().timeIntervalSince(started) > 50 {
                    self.rollTaskOver()
                }
            }
        }
    }

    private func rollTaskOver() {
        rollingOver = true
        sink.close()
        request?.endAudio()
        task?.finish()
        // Retire the outgoing task's results BEFORE its text is committed.
        // Otherwise its final delivery lands after the commit and re-states the
        // same words as a fresh partial — the segment appears twice, or worse,
        // replaces the new task's text with the previous 50 seconds.
        epoch += 1
        request = nil
        task = nil
        isRecording = false
        rollingOver = false
        diagnostic = "mic: rolled the recognition task over at 50s"
        // beginTask() commits the partial from the task we just ended, so the
        // text carries across the boundary instead of restarting from empty.
        beginTask(forceNetwork: !usedOnDeviceForThisTask)
    }

    // MARK: Text bookkeeping

    private func commitPartial() {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        committed = committed.isEmpty ? text : committed + " " + text
        partial = ""
        recomputeTranscript()
    }

    private func recomputeTranscript() {
        let joined = [committed, partial]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        transcript = joined
    }

    private nonisolated static func peak(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in stride(from: 0, to: count, by: 8) {
            sum += abs(channel[index])
        }
        let mean = Double(sum) / Double(max(1, count / 8))
        return min(1, mean * 12)
    }
}
