import AVFoundation
import Foundation

/// Speaks the lookup card's line via AVSpeechSynthesizer.
///
/// It deliberately does NOT touch AVAudioSession. The session is owned by
/// `AudioSessionController` (`.playAndRecord` + `.defaultToSpeaker` +
/// `.allowBluetooth`, activated once at launch), so speaking routes to the
/// glasses' speakers when they are connected and to the phone speaker when
/// they aren't — without ever deactivating the session out from under the
/// microphone. That deactivation is what used to kill live transcription the
/// moment a card's line was read out.
@MainActor
final class SpeechManager: NSObject, ObservableObject {
    /// UserDefaults key for the voice chosen in Glasses › Voice. Empty means
    /// the best English voice on the phone.
    static let voiceKey = "speechVoiceIdentifier"

    @Published var speakAloud = true
    @Published private(set) var isSpeaking = false
    /// The voice chosen in Glasses › Voice, or empty for the best one.
    @Published var chosenVoiceID: String = UserDefaults.standard.string(forKey: SpeechManager.voiceKey) ?? "" {
        didSet { UserDefaults.standard.set(chosenVoiceID, forKey: Self.voiceKey) }
    }

    /// Bumped when iOS reports that the installed voices changed, so the
    /// Voice page redraws. The list can fill in after launch.
    @Published private(set) var voicesVersion = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var voicesObserver: NSObjectProtocol?

    override init() {
        super.init()
        synthesizer.delegate = self
        #if DEBUG
        // See `DictationManager.prime()`: no audio in a headless simulator.
        if UserDefaults.standard.bool(forKey: "noAudio") { speakAloud = false }
        #endif
        logVoices("at launch")
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.voicesVersion += 1
                self?.logVoices("after iOS reported a change")
            }
        }
    }

    /// The voice in use and every English voice iOS reports, for the log.
    func logVoices(_ when: String) {
        let all = Self.englishVoices
        let list = all.map { "\($0.name) [\(Self.qualityName($0))]" }.joined(separator: ", ")
        print("[thread] voices \(when): \(all.count) English — \(list)")
        if let voice {
            print("[thread] voice: \(voice.name), \(Self.qualityName(voice)), \(voice.language)\(chosenVoiceID.isEmpty ? " (best available)" : " (chosen)")")
        }
    }

    // MARK: Voices

    /// English voices on this phone, most natural first. Novelty voices and
    /// the user's Personal Voice are left out.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        let here = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix("en")
                    && !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted { a, b in
                let rankA = rank(a, here: here)
                let rankB = rank(b, here: here)
                return rankA == rankB
                    ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    : rankA > rankB
            }
    }

    /// Premium voices first, then Enhanced, then the rest; within each, the
    /// phone's own variety of English first.
    private static func rank(_ voice: AVSpeechSynthesisVoice, here: String) -> Int {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 3
        case .enhanced: quality = 2
        default: quality = 1
        }
        return quality * 10 + (voice.language == here ? 1 : 0)
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    /// The voice cards are spoken in: the one chosen, if it is still on the
    /// phone, otherwise the most natural English one.
    var voice: AVSpeechSynthesisVoice? {
        if !chosenVoiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: chosenVoiceID) {
            return chosen
        }
        return Self.englishVoices.first
    }

    /// Says a short sample in a voice, for choosing one.
    func preview(_ voice: AVSpeechSynthesisVoice) {
        synthesizer.stopSpeaking(at: .immediate)
        say("That's Sam Rivera, design lead at Acme. Ask how the launch went.", in: voice)
    }

    func speak(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        guard speakAloud else {
            print("[thread] not speaking: Speak is off in Meet")
            return
        }
        say(line, in: voice)
    }

    /// Where sound is going right now, for the log.
    private var outputRoute: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.isEmpty
            ? "nowhere"
            : outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
    }

    private func say(_ line: String, in voice: AVSpeechSynthesisVoice?) {
        // Make sure the session is live, but never re-categorise it.
        AudioSessionController.shared.reassert()
        isSpeaking = true
        AudioSessionController.shared.isSpeaking = true
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = voice
        // The natural voices are tuned for the default rate; slowing them
        // down is part of what made the old voice sound robotic.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        utterance.prefersAssistiveTechnologySettings = false
        print("[thread] speaking in \(voice?.name ?? "the default voice") to \(outputRoute): \"\(line.prefix(80))\"")
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finished()
    }

    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        AudioSessionController.shared.isSpeaking = false
        // No setActive(false) here, on purpose.
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        print("[thread] speech started")
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        print("[thread] speech finished")
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        print("[thread] speech cancelled")
        Task { @MainActor in self.finished() }
    }
}
