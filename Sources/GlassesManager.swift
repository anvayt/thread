import AVFoundation
import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs
import UIKit

extension DateFormatter {
    static let lensLog: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Meta Wearables DAT integration: registration, one DeviceSession carrying
/// the camera stream (frames in) and, on glasses that have a lens display,
/// the display capability (lens cards out). Glasses without a display connect
/// for the camera only; their cards are spoken and shown in the app. Falls
/// back to the phone's rear camera when no glasses are connected so the
/// capture loop always works.
///
/// The camera stream can also carry what the glasses' microphones hear, which
/// `GlassesEar` transcribes alongside the phone's own microphone. That is off
/// unless it is switched on in Glasses, and a stream that fails with audio is
/// reopened without it, so a photo never depends on it.
@MainActor
final class GlassesManager: ObservableObject {
    /// How long a glasses photo gets before we stop waiting and use the phone.
    /// Twelve seconds was long enough to stall a whole demo on a dead stream.
    static let glassesPhotoTimeout: Double = 8
    /// How long to wait for the camera stream to actually go live.
    static let streamReadyTimeout: Double = 6
    /// UserDefaults key for "Listen Through Glasses" in the Glasses tab.
    static let listenThroughGlassesKey = "listenThroughGlasses"
    /// UserDefaults key for "Glasses Buttons Start Meet" in the Glasses tab.
    /// On unless it has been switched off.
    static let buttonsStartMeetKey = "glassesButtonsStartMeet"

    @Published var isConnected = false
    @Published var displayReady = false
    /// True while the open camera stream was asked to carry audio.
    @Published private(set) var streamHasAudio = false
    /// Why the glasses' microphones are not being used although the switch
    /// is on. Cleared by reconnecting or flipping the switch.
    @Published private(set) var glassesMicProblem: String?
    /// What the last press of a button on the glasses did, for Diagnostics.
    @Published private(set) var lastButtonReport = ""
    /// Why the glasses' buttons are not reaching Thread, if they aren't.
    @Published private(set) var buttonsProblem: String?
    /// Which camera actually produced the last frame — shown on the result card
    /// so "it used the phone" is visible rather than inferred.
    @Published private(set) var lastFrameSource = ""
    /// iOS camera permission, so a denial is stated instead of surfacing as
    /// "couldn't take a photo".
    @Published private(set) var cameraAuth: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)
    @Published var statusText = "Glasses: not connected" {
        didSet { print("[thread] \(statusText)") }
    }
    /// Every DisplayState transition, newest last. Shown verbatim in Glasses › Diagnostics so
    /// "nothing appeared on the lens" is answerable instead of a guess.
    @Published var displayLog: [String] = []
    /// Identifies each capture so a stale timeout cannot cancel a newer one.
    private var photoAttempt: UInt64 = 0

    private var session: DeviceSession?
    private var selector: AutoDeviceSelector?
    /// Whether `selector` was built to pick only display-capable glasses.
    private var selectorWantsDisplay = false
    private var camera: Camera?
    private var stream: MWDATCamera.Stream?
    private var display: Display?
    private var tokens: [any AnyListenerToken] = []
    /// Listeners on the camera stream. Kept apart from `tokens` so the stream
    /// can be closed and reopened without dropping the session's listeners.
    private var streamTokens: [any AnyListenerToken] = []
    /// Follows the session's state once it has started.
    private var sessionWatch: Task<Void, Never>?
    /// The glasses' buttons, while "Glasses Buttons Start Meet" is on.
    private var inputs: Inputs?
    /// Listeners and the event loop for `inputs`, kept apart so the buttons
    /// can be switched off and on without touching the session.
    private var inputTokens: [any AnyListenerToken] = []
    private var inputsTask: Task<Void, Never>?
    /// A capture-button press waiting to see whether it is half of a double
    /// press, which the glasses report as a press followed by a double press.
    private var pendingCapturePress: Task<Void, Never>?
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?
    private let phoneFallback = PhoneCameraFallback()

    /// True when the user flipped "Always Use iPhone Camera" in Glasses.
    private var forcePhoneCamera: Bool {
        UserDefaults.standard.bool(forKey: "usePhoneCamera")
    }

    /// Observe registration + device changes. Wearables.configure() runs in
    /// the App initializer before this.
    func configure() {
        if let bootError = DATBootstrap.error {
            statusText = "SDK init failed: \(bootError)"
            return
        }
        statusText = "Glasses: SDK ready (\(Wearables.shared.registrationState))"
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                updateStatus(registration: state)
            }
        }
    }

    private func updateStatus(registration: RegistrationState) {
        switch registration {
        case .registered:
            if !isConnected { statusText = "Glasses: registered. Tap Connect." }
        case .registering:
            statusText = "Glasses: registering…"
        case .available:
            statusText = "Glasses: tap Connect to register"
        case .unavailable:
            statusText = "Glasses: install/open the Meta AI app"
        @unknown default:
            statusText = "Glasses: unknown state"
        }
    }

    func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            Task { await connect() }
        }
    }

    func connect() async {
        // `Wearables.shared` traps if configure() failed at launch.
        if let bootError = DATBootstrap.error {
            statusText = "SDK init failed: \(bootError)"
            return
        }
        do {
            if Wearables.shared.registrationState != .registered {
                statusText =
                    "Opening the Meta AI app to register… (state: \(Wearables.shared.registrationState))"
                do {
                    try await Wearables.shared.startRegistration()
                } catch {
                    statusText = "Registration failed: \(error)"
                    return
                }
                for await state in Wearables.shared.registrationStateStream() {
                    statusText = "Registration: \(state)"
                    if state == .registered { break }
                }
            }

            var permission = try await Wearables.shared.checkPermissionStatus(.camera)
            if permission != .granted {
                permission = try await Wearables.shared.requestPermission(.camera)
            }
            guard permission == .granted else {
                statusText = "Glasses: camera permission denied in the Meta AI app"
                return
            }
            await prepareGlassesMic()

            let wearables = Wearables.shared
            let deviceCount = wearables.devices.count
            statusText = "Devices seen: \(deviceCount). Checking compatibility…"
            if deviceCount == 0 {
                statusText =
                    "No glasses found. Open the Meta AI app, confirm the glasses show Connected, and check Thread's Bluetooth and Local Network switches in iOS Settings."
                return
            }

            // Diagnose each visible device before trying a session.
            for identifier in wearables.devices {
                guard let device = wearables.deviceForIdentifier(identifier)
                else { continue }
                let compat = device.compatibility()
                let link = device.linkState
                statusText =
                    "\(device.nameOrId()): link=\(link), compat=\(compat.displayString)"
                if compat == .deviceUpdateRequired {
                    statusText =
                        "\(device.nameOrId()) needs a glasses software update. Opening the Meta AI update screen…"
                    try? await Wearables.shared.openFirmwareUpdate()
                    return
                }
                if compat == .sdkUpdateRequired {
                    statusText =
                        "\(device.nameOrId()): app SDK too old for this device (sdkUpdateRequired)."
                    return
                }
                if link == .disconnected {
                    statusText =
                        "\(device.nameOrId()) is paired but disconnected. Wake the glasses (open the hinges or wear them) and check Meta AI shows Connected."
                    return
                }
            }

            // Glasses with a lens display get the lens cards as well. Glasses
            // without one (camera-and-audio models) still give the photo and
            // the spoken line, so they are accepted too. When both kinds are
            // paired, the display-capable pair is preferred.
            let displayCapable = wearables.devices.contains { identifier in
                wearables.deviceForIdentifier(identifier)?.supportsDisplay() == true
            }

            // The selector resolves its active device asynchronously — creating
            // a session before it resolves throws noEligibleDevice. A cached
            // selector is reused only while it still matches the kind of
            // glasses that are present.
            if self.selector == nil || selectorWantsDisplay != displayCapable {
                self.selector = displayCapable
                    ? AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
                    : AutoDeviceSelector(wearables: wearables)
                selectorWantsDisplay = displayCapable
            }
            guard let selector = self.selector else { return }
            var waited = 0
            while selector.activeDevice == nil && waited < 24 {
                statusText = "Waiting for glasses to become active… \(waited / 2)s"
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            guard selector.activeDevice != nil else {
                statusText =
                    "Glasses visible but never became the active device (10s). Close other glasses apps, toggle the glasses off/on in Meta AI, then retry.\n\(wearablesDeviceSummary())"
                return
            }

            let session = try wearables.createSession(deviceSelector: selector)
            // Capture streams before start() — no replay on state events. The
            // stop REASON arrives on the error publisher, not the state stream.
            let states = session.stateStream()
            var lastError: DeviceSessionError?
            tokens.append(
                session.errorPublisher.listen { error in
                    Task { @MainActor in lastError = error }
                }
            )
            try session.start()
            if session.state != .started {
                for await state in states {
                    if state == .started { break }
                    if state == .stopped {
                        // Give the error publisher a beat to deliver the reason.
                        try? await Task.sleep(for: .milliseconds(400))
                        if case .datAppOnTheGlassesUpdateRequired = lastError {
                            statusText =
                                "The glasses' DAT app needs an update. Opening the update screen in Meta AI…"
                            try? await Wearables.shared.openDATGlassesAppUpdate()
                            return
                        }
                        if let lastError, "\(lastError)".contains("Device unavailable") {
                            // What the glasses say when they are not being
                            // worn, or are folded, so a session can't start.
                            statusText =
                                "Glasses: not ready. Put them on, with the arms open, then tap Connect."
                            log("session refused: device unavailable (glasses not worn or folded)")
                            return
                        }
                        statusText =
                            "Session stopped: \(lastError.map { "\($0)" } ?? "no reason delivered")\n\(wearablesDeviceSummary())"
                        return
                    }
                }
            }
            self.session = session
            isConnected = true
            watch(session)
            updateKeepAwake()
            if displayCapable {
                statusText = "Glasses: connected"
                attachDisplay(session: session)
            } else {
                // No lens to attach. Say so plainly instead of trying
                // addDisplay() and reporting a failure that isn't one.
                LensCards.shared.noDisplay = true
                statusText =
                    "Glasses: connected, camera and audio. These glasses have no display, so cards are spoken and shown in the app."
                log("glasses have no display — skipping the lens, using camera and audio only")
            }
            attachButtons(to: session)
            // Cards are spoken through the glasses when they are the sound
            // output; nudge iOS back to them if it fell back to the speaker.
            AudioSessionController.shared.preferBluetoothOutput()
        } catch {
            // Keep the device diagnostics visible alongside the failure.
            let info = wearablesDeviceSummary()
            statusText = "Glasses: \(error.localizedDescription)\n\(info)"
        }
    }

    // MARK: Buttons on the glasses

    /// True unless "Glasses Buttons Start Meet" has been switched off.
    var buttonsStartMeet: Bool {
        UserDefaults.standard.object(forKey: Self.buttonsStartMeetKey) as? Bool ?? true
    }

    /// Follows the session after it has started. The glasses change its state
    /// themselves: a single tap on the temple pauses it and another resumes
    /// it, and a long press, folding the glasses or losing the connection
    /// stops it. Those two touches belong to the glasses; Thread never sees
    /// them as presses.
    private func watch(_ session: DeviceSession) {
        sessionWatch?.cancel()
        sessionWatch = Task { @MainActor [weak self] in
            var wasPaused = false
            for await state in session.stateStream() {
                guard let self, self.session === session, !Task.isCancelled else { return }
                switch state {
                case .paused:
                    wasPaused = true
                    self.statusText = "Glasses: paused. Tap the temple again to resume."
                    self.log("session paused by the glasses")
                case .started:
                    guard wasPaused else { break }
                    wasPaused = false
                    self.statusText = "Glasses: connected"
                    self.log("session resumed")
                    // Meta's known issue: capabilities in testing, which the
                    // buttons are, do not come back with a resumed session.
                    // Add them again.
                    self.detachButtons()
                    self.attachButtons(to: session)
                case .stopped:
                    self.sessionEnded(session)
                    return
                default:
                    break
                }
            }
        }
    }

    /// Asks the glasses to send their button presses to Thread: the capture
    /// button, a double tap on the temple, and the action button on glasses
    /// that have one. Each starts Meet, or ends the turn while Meet is
    /// listening, as the Done button does.
    ///
    /// Meta offers this to apps in testing only, which an app reached through
    /// Developer Mode in the Meta AI app is. A refusal leaves the phone's Meet
    /// button working and says why in Glasses.
    private func attachButtons(to session: DeviceSession) {
        guard buttonsStartMeet, inputs == nil else { return }
        buttonsProblem = nil
        do {
            guard let inputs = try session.addInputs(
                configuration: InputsConfiguration(sources: [.captureButton, .captouch, .actionButton])
            ) else {
                buttonsProblem = "these glasses do not offer their buttons to apps"
                log("buttons: not offered by these glasses")
                return
            }
            self.inputs = inputs
            inputTokens.append(
                inputs.statePublisher.listen { [weak self] state in
                    Task { @MainActor in self?.log("buttons: \(state)") }
                }
            )
            inputTokens.append(
                inputs.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        self?.buttonsProblem = error.description
                        self?.log("buttons error: \(error)")
                    }
                }
            )
            inputsTask = Task { @MainActor [weak self] in
                for await event in inputs.events {
                    guard !Task.isCancelled else { return }
                    self?.buttonEvent(event)
                }
            }
            log("buttons: listening for the capture button and a double tap")
        } catch {
            buttonsProblem = "\(error)"
            log("buttons could not be added: \(error)")
        }
    }

    /// Stops listening to the buttons. Safe to call when nothing is attached.
    private func detachButtons() {
        pendingCapturePress?.cancel()
        pendingCapturePress = nil
        inputsTask?.cancel()
        inputsTask = nil
        inputTokens.removeAll()
        if inputs != nil {
            try? session?.removeInputs()
        }
        inputs = nil
    }

    private func buttonEvent(_ event: InputEvent) {
        switch event {
        case .capture(let press, _, _):
            switch press {
            case .shortPress:
                // Meta's known issue: a double press arrives as a short press
                // and then a double press. Wait a moment so it counts once.
                pendingCapturePress?.cancel()
                pendingCapturePress = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    self?.buttonPressed("the capture button")
                }
            case .doublePress:
                pendingCapturePress?.cancel()
                pendingCapturePress = nil
                buttonPressed("a double press of the capture button")
            case .hold:
                buttonPressed("holding the capture button")
            }
        case .select(let source, _):
            guard source == .captouch else { return }
            buttonPressed("a double tap on the temple")
        case .button:
            buttonPressed("the action button")
        default:
            break
        }
    }

    /// What every button does: start Meet, or end the turn while it listens.
    private func buttonPressed(_ what: String) {
        let stamp = DateFormatter.lensLog.string(from: Date())
        let engine = MeetEngine.shared
        let report: String
        if engine.phase == .listening {
            engine.finishListening()
            report = "ended listening"
        } else if engine.glassesTapped() {
            report = "started Meet"
        } else {
            report = "arrived while Meet was looking someone up"
        }
        lastButtonReport = "\(stamp): \(what) \(report)."
        log("button: \(what) — \(report)")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Call after the "Glasses Buttons Start Meet" switch changes.
    func buttonsPreferenceChanged() {
        updateKeepAwake()
        if buttonsStartMeet, let session, isConnected {
            attachButtons(to: session)
        } else {
            detachButtons()
            buttonsProblem = nil
        }
    }

    /// The glasses ended the session, so nothing here is connected any more.
    private func sessionEnded(_ session: DeviceSession) {
        guard self.session === session else { return }
        log("session stopped by the glasses")
        // Already stopped, so there is nothing for disconnect() to stop.
        self.session = nil
        disconnect()
        statusText =
            "Glasses: the session ended (a long press on the temple, folded glasses or a lost connection). Tap Connect to start again."
    }

    /// The camera stream this app uses pauses when the app is not on screen,
    /// so a button on the glasses could not take a photo from a locked phone.
    /// While the buttons start Meet, the phone is kept awake for as long as
    /// the glasses are connected.
    func updateKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = buttonsStartMeet && isConnected
    }

    // MARK: Glasses microphones

    /// True when the user switched on "Also listen through the glasses".
    private var wantsGlassesMic: Bool {
        UserDefaults.standard.bool(forKey: Self.listenThroughGlassesKey)
    }

    /// Whether this capture should expect audio from the glasses.
    var listensThroughGlasses: Bool {
        wantsGlassesMic && isConnected && !forcePhoneCamera && glassesMicProblem == nil
    }

    /// One line for Connect: is the glasses' microphone in use, and if not, why.
    var glassesMicSummary: String {
        if !wantsGlassesMic { return "Off. Only the phone listens." }
        if let glassesMicProblem { return "Not in use: \(glassesMicProblem)." }
        if !isConnected { return "On. Starts once the glasses are connected." }
        if forcePhoneCamera {
            return "Not in use: the audio comes with the glasses camera, and the iPhone camera is always used."
        }
        return streamHasAudio
            ? "On. The glasses were asked to send audio with the camera."
            : "On. Starts with the next capture."
    }

    /// Asks for the glasses' own microphone permission when listening through
    /// them is switched on. It has to be granted before the camera is added:
    /// a stream opened with audio and without it is ended by the glasses.
    ///
    /// A refusal or an error here only turns the glasses' microphone off. The
    /// connection carries on, because the camera does not need it.
    private func prepareGlassesMic() async {
        glassesMicProblem = nil
        guard wantsGlassesMic else { return }
        do {
            var permission = try await Wearables.shared.checkPermissionStatus(.microphone)
            if permission != .granted {
                statusText = "Opening the Meta AI app for the glasses' microphone permission…"
                permission = try await Wearables.shared.requestPermission(.microphone)
            }
            if permission != .granted {
                glassesMicProblem = "the microphone permission was not granted in the Meta AI app"
            }
        } catch {
            glassesMicProblem = "the microphone permission could not be checked (\(error.localizedDescription))"
        }
        if let glassesMicProblem { log("glasses microphone off: \(glassesMicProblem)") }
    }

    /// Call after the "Also listen through the glasses" switch changes.
    func listenPreferenceChanged() async {
        glassesMicProblem = nil
        guard isConnected else { return }
        if wantsGlassesMic {
            // The permission has to be in place before a session adds its
            // camera, so start again from the top.
            await reconnect()
        } else {
            // The next capture reopens the stream without audio.
            closeCamera()
        }
    }

    /// Stops the camera and its stream. The next capture opens a new one.
    private func closeCamera() {
        // Releasing a token stops its listener; do that before the camera goes.
        streamTokens.removeAll()
        camera?.stop()
        camera = nil
        stream = nil
        streamHasAudio = false
    }

    /// A stream that was opened with audio and then fails may be failing
    /// because of the audio, so it is closed and the next one is opened
    /// without. Errors that have nothing to do with it (folded glasses, heat,
    /// battery) leave the switch alone.
    private func streamFailed(_ error: StreamError, withAudio: Bool) {
        statusText = "Glasses stream: \(error.localizedDescription)"
        log("stream error: \(error)")
        guard withAudio else { return }
        switch error {
        case .audioStreamingError, .videoStreamingError, .permissionDenied, .internalError, .timeout:
            dropGlassesMic(
                "the glasses ended a stream that carried audio (\(error.localizedDescription)), so the camera now runs without it"
            )
        default:
            break
        }
    }

    /// Stops using the glasses' microphones until the next reconnect, and
    /// closes the stream that carried them.
    private func dropGlassesMic(_ reason: String) {
        guard glassesMicProblem == nil else { return }
        glassesMicProblem = reason
        log("glasses microphone off: \(reason)")
        closeCamera()
    }

    /// Adds the display capability to the already-started session and hands
    /// it to LensCards once DisplayState.started arrives. The listener
    /// token lives in `tokens` — dropping it silently stops updates.
    private func attachDisplay(session: DeviceSession) {
        do {
            let display = try session.addDisplay()
            // Hand the display over BEFORE start() so the very first
            // DisplayState.started already has somewhere to land.
            self.display = display
            LensCards.shared.display = display
            log("display attached (state: \(display.state))")
            tokens.append(
                display.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        let ready = (state == .started)
                        LensCards.shared.ready = ready
                        self.displayReady = ready
                        self.log("DisplayState → \(state)")
                        if ready {
                            self.statusText = "Glasses: connected, lens display ready."
                        } else {
                            self.statusText =
                                "Glasses: connected, but the lens display is \(state). Cards will not show yet."
                        }
                    }
                }
            )
            display.start()
            log("display.start() called")
            // start() is synchronous but the state event can race the
            // listener registration — read the state directly as a backstop.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, let display = self.display else { return }
                let ready = (display.state == .started)
                if ready != self.displayReady {
                    LensCards.shared.ready = ready
                    self.displayReady = ready
                    self.log("polled DisplayState → \(display.state)")
                }
            }
        } catch {
            log("addDisplay failed: \(error.localizedDescription)")
            statusText = "Glasses connected, but the display didn't attach: \(error.localizedDescription)"
        }
    }

    private func log(_ line: String) {
        let stamp = DateFormatter.lensLog.string(from: Date())
        displayLog.append("\(stamp)  \(line)")
        if displayLog.count > 40 { displayLog.removeFirst(displayLog.count - 40) }
        print("[thread/lens] \(line)")
    }

    private func wearablesDeviceSummary() -> String {
        let wearables = Wearables.shared
        let parts = wearables.devices.compactMap { identifier -> String? in
            guard let device = wearables.deviceForIdentifier(identifier)
            else { return nil }
            return "\(device.nameOrId()): link=\(device.linkState), compat=\(device.compatibility().displayString)"
        }
        return parts.isEmpty ? "(no devices visible)" : parts.joined(separator: " · ")
    }

    /// Releases the phone camera when the capture loop is idle.
    func releasePhoneCamera() {
        phoneFallback.stop()
    }

    /// Full teardown + reconnect without quitting the app. When a session or
    /// stream dies there is no recovery path today, which is why a restart was
    /// the only way back.
    func reconnect() async {
        log("reconnect requested — tearing down")
        disconnect()
        photoContinuation = nil
        try? await Task.sleep(for: .milliseconds(600))
        await connect()
    }

    func disconnect() {
        log("disconnect requested")
        display?.stop()
        display = nil
        LensCards.shared.display = nil
        LensCards.shared.ready = false
        LensCards.shared.noDisplay = false
        displayReady = false
        sessionWatch?.cancel()
        sessionWatch = nil
        detachButtons()
        closeCamera()
        session?.stop()
        session = nil
        tokens.removeAll()
        isConnected = false
        glassesMicProblem = nil
        updateKeepAwake()
        statusText = "Glasses: not connected"
    }

    // MARK: Camera permission

    var cameraBlocked: Bool {
        cameraAuth == .denied || cameraAuth == .restricted
    }

    /// Plain-English camera state for the Meet and Connect panels.
    var cameraAuthSummary: String {
        switch cameraAuth {
        case .authorized: return "Camera: allowed"
        case .denied: return "Camera: off for Thread in Settings"
        case .restricted: return "Camera: restricted on this device"
        case .notDetermined: return "Camera: not asked yet"
        @unknown default: return "Camera: unknown"
        }
    }

    func refreshCameraAuth() {
        cameraAuth = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Photo from the glasses camera when connected; phone camera when the
    /// fallback toggle is on, no glasses are available, or the glasses camera
    /// doesn't deliver.
    ///
    /// There is no path here that returns nil while a working camera exists. A
    /// refused `capturePhoto`, a stream that never delivers, and a throw from
    /// `ensureStream` all fall through to the phone — a dead glasses stream
    /// costs \(Self.glassesPhotoTimeout)s, not the capture.
    func capturePhoto() async -> UIImage? {
        defer {
            // A capture can nudge the audio route; re-assert (never deactivate)
            // so live transcription survives taking a photo.
            AudioSessionController.shared.reassert()
        }
        refreshCameraAuth()
        guard isConnected, !forcePhoneCamera, let session else {
            return await phoneCapture()
        }
        do {
            // The glasses pause a session themselves: a tap on the temple does
            // it, and so does putting them on after a stream has started. A
            // capture asked for from the phone means "take it now", so ask
            // them to carry on rather than going straight to the phone camera.
            if session.state == .paused {
                session.resume()
                var waited = 0.0
                while session.state != .started, waited < 3 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 0.1
                }
                guard session.state == .started else {
                    log("session is paused and did not resume (state: \(session.state)) — using the phone")
                    statusText = "Glasses: paused, so the iPhone camera was used. Tap the temple to resume them."
                    return await phoneCapture()
                }
                log("session was paused — resumed for this capture")
            }

            // A stream that paused with its session comes back by itself once
            // the session resumes, which is where a tap on the temple leaves
            // it. Give it a moment before ensureStream starts it afresh.
            if let paused = self.stream, session.state == .started {
                var waited = 0.0
                while paused.state == .paused, waited < 2 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 0.1
                }
            }
            var stream = try ensureStream(session: session)
            let askedForAudio = streamHasAudio

            // The stream is started but not necessarily live yet. capturePhoto
            // on a stream that hasn't reached .streaming is silently dropped —
            // it never delivers on photoDataPublisher and we time out into the
            // phone. Wait for it, the same way the display waits for .started.
            var waited = await waitUntilStreaming(stream)
            if stream.state != .streaming, askedForAudio {
                // The stream that would not start was asked to carry audio.
                // Open one without, so the photo does not depend on the
                // glasses' microphones.
                dropGlassesMic("the camera stream did not start with audio, so it now runs without")
                stream = try ensureStream(session: session)
                waited = await waitUntilStreaming(stream)
            }
            if stream.state != .streaming {
                log("glasses stream never reached .streaming (state=\(stream.state)) — using the phone")
                statusText = "Glasses camera not streaming. Used the iPhone camera."
                return await phoneCapture()
            }
            log("glasses stream live after \(String(format: "%.1f", waited))s")

            photoAttempt &+= 1
            let attempt = photoAttempt
            let image: UIImage? = await withCheckedContinuation { continuation in
                photoContinuation = continuation
                if !stream.capturePhoto(format: .jpeg) {
                    photoContinuation = nil
                    continuation.resume(returning: nil)
                    return
                }
                // Photo arrives on photoDataPublisher; guard with a timeout that
                // only ever cancels ITS OWN attempt. The previous version had no
                // identity, so a stale timer from an earlier capture would wake
                // up and kill whichever capture happened to be in flight.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.glassesPhotoTimeout))
                    guard let self, self.photoAttempt == attempt,
                          let pending = self.photoContinuation
                    else { return }
                    self.photoContinuation = nil
                    self.log("glasses photo timed out after \(Self.glassesPhotoTimeout)s")
                    pending.resume(returning: nil)
                }
            }
            if let image {
                lastFrameSource = "glasses camera"
                log("frame from the glasses camera")
                return image
            }
            log("glasses camera returned nothing — falling back to the phone")
            statusText = "Glasses camera gave no photo. Used the iPhone camera."
            return await phoneCapture()
        } catch {
            statusText = "Glasses: \(error.localizedDescription)"
            log("glasses stream failed (\(error.localizedDescription)) — falling back to the phone")
            return await phoneCapture()
        }
    }

    /// Waits for the stream to go live, up to `streamReadyTimeout`, and returns
    /// how long that took.
    private func waitUntilStreaming(_ stream: MWDATCamera.Stream) async -> Double {
        var waited = 0.0
        while stream.state != .streaming, waited < Self.streamReadyTimeout {
            try? await Task.sleep(for: .milliseconds(120))
            waited += 0.12
        }
        return waited
    }

    private func phoneCapture() async -> UIImage? {
        let image = await phoneFallback.capture()
        // The prompt may have been answered during that call.
        refreshCameraAuth()
        lastFrameSource = image == nil ? "no camera" : "iPhone camera"
        if image == nil {
            log("iPhone camera returned nothing (\(cameraAuthSummary))")
        }
        return image
    }

    private func ensureStream(
        session: DeviceSession
    ) throws -> MWDATCamera.Stream {
        // Reuse the stream we already own. A second addStream for the same
        // capability is rejected (capabilityAlreadyActive), so if the existing
        // one has gone idle after a capture, restart it rather than making a
        // new one — that rejection was why only the first photo worked.
        if let existing = stream {
            if existing.state != .streaming {
                log("glasses stream idle (state=\(existing.state)) — restarting it")
                existing.start()
            }
            return existing
        }

        // 16 kHz mono is what speech recognition wants, and the least the
        // glasses can be asked to send.
        let withAudio = wantsGlassesMic && glassesMicProblem == nil
        let config = withAudio
            ? StreamConfiguration(
                videoCodec: .raw,
                audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
                resolution: .medium, frameRate: 15
            )
            : StreamConfiguration(
                videoCodec: .raw, resolution: .medium, frameRate: 15
            )
        guard let camera = try session.addCamera(config: config) else {
            throw NSError(
                domain: "Thread", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Session not started yet"
                ]
            )
        }
        let stream = camera.stream

        streamTokens.append(
            stream.photoDataPublisher.listen { [weak self] photoData in
                Task { @MainActor in
                    guard let self, let pending = self.photoContinuation else {
                        return
                    }
                    self.photoContinuation = nil
                    pending.resume(returning: UIImage(data: photoData.data))
                }
            }
        )
        streamTokens.append(
            stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    self?.streamFailed(error, withAudio: withAudio)
                }
            }
        )
        if withAudio {
            // Listening has to be in place before the stream starts. The
            // frames arrive on the SDK's own thread and are handed straight
            // over there, because a buffer is only good inside this call.
            let ear = GlassesEar.shared
            let sink = ear.sink
            let tally = ear.tally
            let probe = ear.probe
            streamTokens.append(
                stream.audioFramePublisher.listen { frame in
                    tally.add(frame.pcmBuffer)
                    let accepted = sink.append(frame.pcmBuffer)
                    probe.record(frame.pcmBuffer, accepted: accepted)
                }
            )
            log("camera stream opened with audio from the glasses' microphones")
        }

        stream.start()
        self.camera = camera
        self.stream = stream
        streamHasAudio = withAudio
        return stream
    }
}
