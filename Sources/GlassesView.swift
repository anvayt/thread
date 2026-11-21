import AVFoundation
import Speech
import SwiftUI

/// The glasses and everything Thread needs, laid out like a device page in
/// Settings: the glasses at the top with one button to connect them, then
/// their features, the camera, permissions, the backend and help. Glasses are
/// optional everywhere in Thread, so nothing here blocks the phone-only path.
///
/// The raw status strings that help when something does not work on real
/// hardware are one level down, under Diagnostics.
struct GlassesView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @EnvironmentObject private var speech: SpeechManager
    @ObservedObject private var cards = LensCards.shared
    @ObservedObject private var dictation = DictationManager.shared
    @ObservedObject private var audio = AudioSessionController.shared
    @AppStorage("usePhoneCamera") private var usePhoneCamera = false
    @AppStorage(GlassesManager.listenThroughGlassesKey) private var listenThroughGlasses = false
    @AppStorage(GlassesManager.buttonsStartMeetKey) private var buttonsStartMeet = true
    @AppStorage(BackendAPI.baseURLKey) private var baseURL = BackendAPI.defaultBase
    @AppStorage(WelcomeView.seenKey) private var hasSeenWelcome = false
    @AppStorage(BackendAPI.wearerNameKey) private var wearerName = ""
    @AppStorage(RecentAudio.secondsKey) private var momentBefore = 0.0

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                #if DEBUG
                // Only in a run started with `-mockGlasses YES`.
                if SimulatedGlasses.isOn {
                    SimulatedGlassesSection()
                }
                #endif
                if glasses.isConnected {
                    displaySection
                }
                youSection
                listeningSection
                voiceSection
                featuresSection
                cameraSection
                permissionsSection
                appSection
            }
            .navigationTitle("Glasses")
            .onAppear { glasses.refreshCameraAuth() }
        }
    }

    // MARK: The glasses

    /// The status under the name: "Connected" once they are, otherwise the
    /// manager's own line without its "Glasses: " prefix, which says what to
    /// do next. The longer detail is in Diagnostics.
    private var glassesDetail: String {
        if glasses.isConnected { return "Connected" }
        let text = glasses.statusText
        guard text.hasPrefix("Glasses: ") else { return text }
        let rest = text.dropFirst("Glasses: ".count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    private var deviceSection: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(glasses.isConnected ? Color.primary : Color.secondary)
                    .symbolEffect(.bounce, value: glasses.isConnected)
                    .frame(height: 80)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("Meta Glasses")
                        .font(.title2.weight(.semibold))
                    Text(glassesDetail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                Group {
                    if glasses.isConnected {
                        Button("Disconnect") { glasses.toggleConnection() }
                            .buttonStyle(.glass)
                    } else {
                        Button("Connect") { glasses.toggleConnection() }
                            .buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)
                .font(.body.weight(.semibold))
                .frame(minWidth: 160)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } footer: {
            if !glasses.isConnected {
                Text("Pair your glasses in the Meta AI app first. Without glasses, Thread uses the iPhone camera and speaker.")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            if cards.noDisplay {
                LabeledContent("Display", value: "None")
            } else {
                Text(cards.lensStatus)
                    .foregroundStyle(cards.lastSendFailed ? Color.red : Color.primary)
                if cards.connected {
                    Button("Send Test Card") {
                        Task { await LensCards.shared.showNote("Thread test card. The lens is working.") }
                    }
                    Button("Clear Display") {
                        Task { await LensCards.shared.clear() }
                    }
                }
            }
        } header: {
            if !cards.noDisplay {
                Text("Display")
            }
        } footer: {
            if cards.noDisplay {
                Text("Cards are spoken and shown in the app. To hear them in the glasses, make the glasses the iPhone's audio output and keep Speak on in Meet.")
            }
        }
    }

    // MARK: Features

    @ViewBuilder
    private var featuresSection: some View {
        Section {
            Toggle("Buttons Start Meet", isOn: $buttonsStartMeet)
                .onChange(of: buttonsStartMeet) { glasses.buttonsPreferenceChanged() }
            if buttonsStartMeet, glasses.isConnected, let problem = glasses.buttonsProblem {
                ProblemLabel("The glasses' buttons aren't reaching Thread: \(problem).")
            }
        } header: {
            Text("Glasses Controls")
        } footer: {
            Text("Press the capture button or double-tap the temple to start Meet, and press again to stop listening. A single tap pauses the glasses and a long press ends the session; the glasses keep those for themselves. The iPhone stays awake while the glasses are connected.")
        }
        Section {
            Toggle("Listen Through Glasses", isOn: $listenThroughGlasses)
                .onChange(of: listenThroughGlasses) {
                    Task { await glasses.listenPreferenceChanged() }
                }
            if listenThroughGlasses, let problem = glasses.glassesMicProblem {
                ProblemLabel(problem)
            }
        } header: {
            Text("Experimental")
        } footer: {
            Text("Also transcribes what the glasses' microphones hear, and keeps whichever transcript caught more words. Asks for one more permission in the Meta AI app. Not yet tried on real glasses.")
        }
    }

    // MARK: You

    private var youSection: some View {
        Section {
            TextField("Your Name", text: $wearerName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onSubmit { Task { await DictationManager.shared.refreshHintNames() } }
        } header: {
            Text("You")
        } footer: {
            Text("You introduce yourself too. With your name here, Thread never saves you as the person you're meeting, and hears your name correctly.")
        }
    }

    // MARK: Listening

    private var listeningSection: some View {
        Section {
            Picker("Include the Moment Before", selection: $momentBefore) {
                Text("Off").tag(0.0)
                Text("5 Seconds").tag(5.0)
                Text("10 Seconds").tag(10.0)
            }
            .onChange(of: momentBefore) { _, seconds in
                DictationManager.shared.recent.setCapacity(seconds)
            }
        } header: {
            Text("Listening")
        } footer: {
            Text("Meet also hears the last few seconds before you press, so a name said just as you meet is caught. Those seconds stay in the iPhone's memory, are overwritten as they pass, and are only transcribed when you start Meet. Nothing is saved or sent otherwise.")
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            NavigationLink {
                VoiceView()
            } label: {
                LabeledContent("Voice", value: speech.voice?.name ?? "Default")
            }
            HStack {
                LabeledContent("Sound Output", value: audio.outputName.isEmpty ? "None" : audio.outputName)
                SoundOutputPicker()
                    .frame(width: 30, height: 30)
            }
        } header: {
            Text("Spoken Cards")
        } footer: {
            Text("Cards play wherever the iPhone's sound goes. Thread asks for the glasses whenever they connect; to choose by hand, tap the button and pick them.")
        }
    }

    // MARK: Camera

    private var cameraSection: some View {
        Section {
            Toggle("Always Use iPhone Camera", isOn: $usePhoneCamera)
            if !glasses.lastFrameSource.isEmpty {
                LabeledContent(
                    "Last Photo",
                    value: glasses.lastFrameSource.prefix(1).uppercased() + glasses.lastFrameSource.dropFirst()
                )
            }
        } header: {
            Text("Camera")
        } footer: {
            Text(
                usePhoneCamera
                    ? "Photos come from the iPhone's rear camera, even with glasses connected."
                    : "Photos come from the glasses when they are connected, and from the iPhone when they are not."
            )
        }
    }

    // MARK: Permissions

    private var speechAuthText: String {
        switch dictation.speechAuth {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Asked"
        @unknown default: return "Unknown"
        }
    }

    private var cameraAuthText: String {
        switch glasses.cameraAuth {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Asked"
        @unknown default: return "Unknown"
        }
    }

    private var permissionsSection: some View {
        Section {
            LabeledContent("Microphone", value: dictation.micGranted ? "Allowed" : "Off")
            LabeledContent("Speech Recognition", value: speechAuthText)
            LabeledContent("Camera", value: cameraAuthText)
            if !dictation.isUsable || glasses.cameraBlocked {
                OpenSettingsButton()
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Thread listens through the iPhone's microphone, and only after you tap Meet.")
        }
    }

    // MARK: Thread

    /// The backend's host and port, for the row that opens its page.
    private var backendHost: String {
        guard let url = URL(string: baseURL), let host = url.host() else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var appSection: some View {
        Group {
            Section {
                NavigationLink {
                    BackendView()
                } label: {
                    LabeledContent("Backend", value: backendHost)
                }
                NavigationLink("Diagnostics") {
                    DiagnosticsView()
                }
            } header: {
                Text("Thread")
            }

            Section {
                NavigationLink("How Thread Works") {
                    GuideView()
                }
                Button("Show Welcome") { hasSeenWelcome = false }
            }
        }
    }
}

// MARK: - Backend

/// Where the backend is, and whether it answers.
struct BackendView: View {
    @AppStorage(BackendAPI.baseURLKey) private var baseURL = BackendAPI.defaultBase
    @State private var password = BackendPassword.value
    @State private var status: String?
    @State private var reachable = false
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $baseURL, prompt: Text(BackendAPI.defaultBase))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await check() } }
            } header: {
                Text("Address")
            } footer: {
                Text("Where your Thread backend is: an https address when it runs on a server, or the “From a phone” address it prints when it runs on a computer on the same Wi-Fi. The default only works in the Simulator.")
            }

            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await check() } }
                    .onChange(of: password) { BackendPassword.value = password }
            } header: {
                Text("Password")
            } footer: {
                Text("The backend's password, kept in this iPhone's Keychain. Leave it empty for a backend on your own Wi-Fi that has none.")
            }

            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if checking {
                            ProgressView()
                        }
                    }
                }
                .disabled(checking)
                if let status {
                    Label {
                        Text(status)
                    } icon: {
                        Image(systemName: reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(reachable ? Color.green : Color.red)
                    }
                }
            }

            if baseURL != BackendAPI.defaultBase {
                Section {
                    Button("Use Default Address") {
                        baseURL = BackendAPI.defaultBase
                        status = nil
                    }
                }
            }
        }
        .navigationTitle("Backend")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            let people = try await BackendAPI.roster()
            reachable = true
            status = people.count == 1
                ? "Connected. 1 person in your network."
                : "Connected. \(people.count) people in your network."
        } catch {
            reachable = false
            status = "Can't reach it. \(error.localizedDescription)"
        }
    }
}

// MARK: - Diagnostics

/// The raw state of the glasses, the microphone and the audio session, for
/// when something does not work on real hardware.
struct DiagnosticsView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @ObservedObject private var dictation = DictationManager.shared
    @ObservedObject private var audio = AudioSessionController.shared
    @ObservedObject private var ear = GlassesEar.shared

    var body: some View {
        Form {
            Section {
                // A full teardown and reconnect, for when a session or stream
                // has died and quitting the app would be the only other way back.
                Button("Reconnect Glasses") {
                    Task { await glasses.reconnect() }
                }
                Button("Check Microphone Again") {
                    Task {
                        await DictationManager.shared.requestAuthorization()
                        AudioSessionController.shared.reassert()
                        DictationManager.shared.prime()
                    }
                }
            }

            Section("Glasses") {
                detail(glasses.statusText)
                if !glasses.lastButtonReport.isEmpty {
                    detail(glasses.lastButtonReport)
                }
                detail(glasses.glassesMicSummary)
                if !ear.lastReport.isEmpty {
                    detail(ear.lastReport)
                }
            }

            Section("Microphone") {
                detail(dictation.authSummary)
                detail(dictation.diagnostic)
                detail(audio.status)
                detail(glasses.cameraAuthSummary)
            }

            if !glasses.displayLog.isEmpty {
                Section("Log") {
                    ForEach(Array(glasses.displayLog.enumerated()), id: \.offset) { _, line in
                        detail(line)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

// MARK: - Voice

/// The English voices on this phone, most natural first. Tapping one chooses
/// it and plays a sample.
struct VoiceView: View {
    @EnvironmentObject private var speech: SpeechManager

    private var voices: [AVSpeechSynthesisVoice] { SpeechManager.englishVoices }

    private var groups: [(title: String, voices: [AVSpeechSynthesisVoice])] {
        ["Premium", "Enhanced", "Standard"].compactMap { quality in
            let matching = voices.filter { SpeechManager.qualityName($0) == quality }
            return matching.isEmpty ? nil : (quality, matching)
        }
    }

    /// True when the phone has nothing better than the standard voices.
    private var onlyStandard: Bool {
        !voices.contains { $0.quality == .premium || $0.quality == .enhanced }
    }

    var body: some View {
        List {
            if onlyStandard {
                Section {
                    Label {
                        Text("For a natural-sounding voice, download a Premium English voice: open the Settings app, search for Voices, choose English, and pick one marked Premium. It appears here once it has downloaded.")
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.voices, id: \.identifier) { voice in
                        Button {
                            speech.chosenVoiceID = voice.identifier
                            speech.preview(voice)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name)
                                        .foregroundStyle(.primary)
                                    Text(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if speech.voice?.identifier == voice.identifier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("Chosen")
                                }
                            }
                            .contentShape(.rect)
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if group.title == groups.last?.title, !onlyStandard {
                        Text("More voices can be downloaded in the Settings app: search for Voices and choose English.")
                    }
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        // Redraw when iOS finishes loading voices or one is downloaded.
        .id(speech.voicesVersion)
        .onAppear { speech.logVoices("on the Voice page") }
    }
}
