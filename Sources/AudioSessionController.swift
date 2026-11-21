import AVFoundation
import Foundation

/// One AVAudioSession for the whole app, configured once and left active.
///
/// Why this exists: the demo needs the microphone (SFSpeechRecognizer), the
/// speaker (AVSpeechSynthesizer TTS) and a camera capture to work in the same
/// second. Previously DictationManager and SpeechManager each set their own
/// category and each called `setActive(false)` when they finished, so whoever
/// stopped last tore the session out from under whoever was still running —
/// that is why the mic and the camera "don't work at the same time".
///
/// Rules enforced here:
///  * category is `.playAndRecord` with `.defaultToSpeaker` + `.allowBluetoothA2DP`
///    so the mic keeps working while TTS plays and audio routes to the glasses,
///    in full quality, when they are the Bluetooth device.
///  * `setActive(true)` happens exactly once, at launch.
///  * `setActive(false)` is never called by feature code. Nothing deactivates
///    the session for the lifetime of the app.
@MainActor
final class AudioSessionController: ObservableObject {
    static let shared = AudioSessionController()

    /// Human-readable state for the UI so a failure is visible, not silent.
    @Published private(set) var status = "audio session: not configured yet"
    @Published private(set) var isActive = false
    /// True while TTS is talking. The dictation tap drops buffers during this
    /// window so Thread never transcribes its own voice.
    @Published var isSpeaking = false

    /// Bumped whenever the audio route changes (glasses connect/disconnect,
    /// headphones in/out). Listeners rebuild their engine graph, because the
    /// input node's format is invalid after a route change.
    @Published private(set) var routeGeneration = 0

    /// Where sound is playing right now, by name ("RB Meta 00SB", "Speaker").
    @Published private(set) var outputName = ""
    /// True when sound is going to a Bluetooth device, such as the glasses,
    /// rather than the iPhone's own speaker.
    @Published private(set) var outputIsBluetooth = false

    private var configured = false

    private init() {}

    /// Configure + activate. Safe to call repeatedly; only the first call does
    /// the work. Called from the App initializer path at launch.
    @discardableResult
    func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if !configured {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [
                        .defaultToSpeaker,
                        // A2DP only, not HFP. With HFP allowed as well, iOS
                        // sends speech to the glasses as call audio (mono,
                        // 8 or 16 kHz), which is what made cards sound
                        // robotic, on real Ray-Ban Meta glasses. Thread
                        // never records from the glasses' call microphone,
                        // so it never needs HFP.
                        .allowBluetoothA2DP,
                        .duckOthers,
                    ]
                )
                observeRouteChanges()
                configured = true
            }
            try session.setActive(true, options: [])
            pinInputToPhoneMic()
            isActive = true
            updateOutput()
            status = "audio session: active · \(routeDescription)"
            return true
        } catch {
            isActive = false
            status = "audio session failed: \(error.localizedDescription)"
            print("[thread] \(status)")
            return false
        }
    }

    /// Re-assert the session without tearing it down — used after an
    /// interruption (phone call, Siri) or a camera capture that stole the
    /// route. Never deactivates.
    func reassert() {
        guard configured else {
            activate()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            pinInputToPhoneMic()
            isActive = true
            updateOutput()
            status = "audio session: active · \(routeDescription)"
        } catch {
            status = "audio session re-activate failed: \(error.localizedDescription)"
            print("[thread] \(status)")
        }
    }

    /// Force capture onto the phone's own microphone.
    ///
    /// The session no longer offers the glasses' headset microphone (HFP) at
    /// all, because taking it drops the whole route to 8 kHz call audio: a bad
    /// microphone for speech recognition, and robotic playback. Naming the
    /// built-in mic as the preferred input still guards against any other
    /// headset taking capture, and keeps output going to the glasses over
    /// A2DP, which is the combination Thread wants.
    func pinInputToPhoneMic() {
        let session = AVAudioSession.sharedInstance()
        guard
            let builtIn = session.availableInputs?.first(where: {
                $0.portType == .builtInMic
            })
        else { return }
        do {
            try session.setPreferredInput(builtIn)
        } catch {
            print("[thread] couldn't pin the phone mic: \(error.localizedDescription)")
        }
    }

    /// True when capture is on the phone's own microphone, which is what the
    /// speech recogniser needs.
    var inputIsPhoneMic: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs
            .first?.portType == .builtInMic
    }

    /// Asks iOS to choose the output again, so sound goes back to the glasses
    /// when they are available. An app cannot pick a Bluetooth speaker itself;
    /// clearing any speaker override and re-activating is what prompts iOS
    /// to prefer the Bluetooth device again. Called when the glasses connect
    /// and whenever a new audio device appears. If the wearer chose the
    /// iPhone speaker in Control Center, iOS keeps that choice.
    func preferBluetoothOutput() {
        guard configured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(.none)
            try session.setActive(true, options: [])
        } catch {
            print("[thread] couldn't re-route sound: \(error.localizedDescription)")
        }
        pinInputToPhoneMic()
        updateOutput()
        print("[thread] sound output: \(outputName)")
    }

    private func updateOutput() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        outputName = outputs.first?.portName ?? ""
        outputIsBluetooth = outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    var routeDescription: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let out = route.outputs.first?.portName ?? "—"
        let mic = route.inputs.first?.portName ?? "—"
        return "in: \(mic) · out: \(out)"
    }

    private func observeRouteChanges() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-pin before listeners rebuild: the glasses connecting is
                // exactly when iOS tries to move capture onto their headset mic.
                self.pinInputToPhoneMic()
                // A device that has just appeared, such as the glasses'
                // Bluetooth audio coming back, gets the sound again.
                if reason == .newDeviceAvailable {
                    self.preferBluetoothOutput()
                }
                self.updateOutput()
                self.routeGeneration += 1
                self.status = "audio session: active · \(self.routeDescription)"
            }
        }

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard
                    let self,
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                if type == .ended {
                    self.reassert()
                    self.routeGeneration += 1
                }
            }
        }

        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configured = false
                self.activate()
                self.routeGeneration += 1
            }
        }
    }
}
