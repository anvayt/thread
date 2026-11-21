#if DEBUG
import Foundation
import MWDATCore
import MWDATMockDevice
import SwiftUI

/// Simulated glasses, for running Thread with no hardware.
///
/// Debug builds only, and only when the app is launched with
/// `-mockGlasses YES`. Meta's Mock Device Kit then stands in for the whole
/// SDK: registration, permissions, a pair of Ray-Ban Meta glasses, their
/// camera and their touchpad. The rest of the app does not know.
///
/// `scripts/simulate.sh` starts the app this way in the iOS Simulator. The
/// glasses are then worked by hand from the "Simulated glasses" section of the
/// Glasses tab (`SimulatedGlassesSection`), or by a script through the
/// commands file.
///
/// Launch arguments:
///
///     -mockGlasses YES
///     -mockGlassesPhoto /path/on/this/Mac/photo.jpg   what a capture returns
///     -mockGlassesVideo /path/on/this/Mac/clip.mov    the stream (h.265)
///     -mockCommands /path/on/this/Mac/commands.txt    see below
///     -noAudio YES                                    no microphone, no speech
///
/// `-noAudio` is for a simulator with no audio hardware, which is what one
/// booted with no Simulator app running has been seen to be. The app aborts
/// there when it opens the microphone.
///
/// Each line appended to the commands file is run once:
///
///     tap, hold                 a single tap or a long press on the temple
///     press, doubletap          the capture button, a double tap on the temple
///     connect, disconnect       the Connect glasses button
///     meet                      the Meet button
///     say Hi, I'm Dana          what was "heard", when there is no microphone
///     tab 3                     switch tab (0 Meet, 1 People, 2 Map, 3 Glasses, 4 Search)
///     set glassesButtonsStartMeet off   flip a switch kept in UserDefaults
///     don, doff, fold, unfold   wearing and folding the glasses
@MainActor
enum SimulatedGlasses {
    /// Posted with the tab index as its object; `RootView` listens.
    static let selectTab = Notification.Name("SimulatedGlasses.selectTab")

    /// How the glasses are being held, for the controls in Glasses. The kit
    /// cannot be asked, so this records what the glasses were last told.
    @MainActor
    final class Posture: ObservableObject {
        @Published fileprivate(set) var worn = false
        @Published fileprivate(set) var folded = false
        /// Set when the kit could not pair the glasses at launch.
        @Published fileprivate(set) var problem: String?

        var summary: String {
            if problem != nil { return "Not paired" }
            if folded { return "Folded" }
            return worn ? "Worn" : "Not worn"
        }
    }

    static let posture = Posture()

    private static var device: (any MockGlasses)?
    private static var commandsRun = 0

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "mockGlasses") }

    /// Call once at launch, after `Wearables.configure()`.
    static func startIfAsked() {
        guard isOn else { return }
        if let bootError = DATBootstrap.error {
            posture.problem = "Meta's SDK did not start, so there are no simulated glasses. \(bootError)"
            return
        }
        MockDeviceKit.shared.enable()
        do {
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
            let defaults = UserDefaults.standard
            if let photo = defaults.string(forKey: "mockGlassesPhoto") {
                glasses.services.camera.setCapturedImage(fileURL: URL(fileURLWithPath: photo))
            }
            if let video = defaults.string(forKey: "mockGlassesVideo") {
                glasses.services.camera.setCameraFeed(fileURL: URL(fileURLWithPath: video))
            }
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            device = glasses
            posture.worn = true
            print("[thread/mock] simulated Ray-Ban Meta glasses paired, on and worn")
        } catch {
            posture.problem = "The simulated glasses could not be paired. \(error)"
            print("[thread/mock] could not pair simulated glasses: \(error)")
        }
    }

    // MARK: What a hand does to the glasses

    /// A tap on the temple. The glasses pause their session.
    static func tap() {
        device?.services.captouch.tap()
    }

    /// A press and hold on the temple. The glasses end their session.
    static func hold() {
        device?.services.captouch.tapAndHold()
    }

    /// A short press of the capture button. It reaches the app as a button
    /// event while the app is listening to the glasses' buttons.
    static func pressCaptureButton() {
        device?.services.input.capture(pressType: .shortPress)
    }

    /// A double tap on the temple, which reaches the app as a select event.
    static func doubleTap() {
        device?.services.input.select()
    }

    /// Glasses that are not worn keep a session they already have, but will
    /// not start a new one ("Device unavailable").
    static func putOn() {
        device?.don()
        posture.worn = true
    }

    static func takeOff() {
        device?.doff()
        posture.worn = false
    }

    /// Folding ends the session, and the kit then treats the glasses as taken
    /// off: after `unfold()` they have to be put on again before they connect.
    static func fold() {
        device?.fold()
        posture.folded = true
        posture.worn = false
    }

    static func unfold() {
        device?.unfold()
        posture.folded = false
    }

    // MARK: The commands file

    /// Follows the commands file for as long as the app runs.
    static func followCommands(glasses: GlassesManager) async {
        guard isOn, let path = UserDefaults.standard.string(forKey: "mockCommands") else { return }
        // Lines already in the file belong to an earlier run.
        commandsRun = lines(at: path).count
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let all = lines(at: path)
            guard all.count > commandsRun else { continue }
            for line in all[commandsRun...] {
                await run(line, glasses: glasses)
            }
            commandsRun = all.count
        }
    }

    private static func lines(at path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func run(_ line: String, glasses: GlassesManager) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        print("[thread/mock] command: \(line)")

        switch command {
        case "tap": tap()
        case "hold": hold()
        case "press": pressCaptureButton()
        case "doubletap": doubleTap()
        case "don": putOn()
        case "doff": takeOff()
        case "fold": fold()
        case "unfold": unfold()
        case "connect": await glasses.connect()
        case "disconnect": glasses.disconnect()
        case "meet": Task { await MeetEngine.shared.runOnce() }
        case "say": DictationManager.shared.setTranscript(argument)
        case "tab":
            NotificationCenter.default.post(name: selectTab, object: Int(argument) ?? 0)
        case "set":
            let pair = argument.split(separator: " ").map(String.init)
            guard pair.count == 2 else { break }
            UserDefaults.standard.set(pair[1] == "on", forKey: pair[0])
            if pair[0] == GlassesManager.buttonsStartMeetKey { glasses.buttonsPreferenceChanged() }
            if pair[0] == GlassesManager.listenThroughGlassesKey {
                await glasses.listenPreferenceChanged()
            }
        default:
            print("[thread/mock] unknown command: \(command)")
        }
    }
}

/// The simulated glasses' own controls, for the Glasses tab: what a hand
/// would do to a real pair. `ConnectView` shows this only when
/// `SimulatedGlasses.isOn`.
struct SimulatedGlassesSection: View {
    @EnvironmentObject private var glasses: GlassesManager
    @ObservedObject private var posture = SimulatedGlasses.posture

    var body: some View {
        Section {
            LabeledContent("State", value: posture.summary)
            if let problem = posture.problem {
                ProblemLabel(problem)
            } else {
                // The temple only does something while a session is running.
                Group {
                    Button("Press the Capture Button") { SimulatedGlasses.pressCaptureButton() }
                    Button("Double-Tap the Temple") { SimulatedGlasses.doubleTap() }
                    Button("Tap the Temple") { SimulatedGlasses.tap() }
                    Button("Press and Hold the Temple") { SimulatedGlasses.hold() }
                }
                .disabled(!glasses.isConnected)
                Button(posture.worn ? "Take Off" : "Put On") {
                    if posture.worn {
                        SimulatedGlasses.takeOff()
                    } else {
                        SimulatedGlasses.putOn()
                    }
                }
                .disabled(posture.folded)
                Button(posture.folded ? "Unfold" : "Fold") {
                    if posture.folded {
                        SimulatedGlasses.unfold()
                    } else {
                        SimulatedGlasses.fold()
                    }
                }
            }
        } header: {
            Text("Simulated Glasses")
        } footer: {
            Text("Meta's simulated glasses stand in for real ones in this debug build. The capture button and a double tap start Meet when Buttons Start Meet is on. A single tap pauses them. A press and hold ends the session, and so does folding them. They only connect while unfolded and worn. They send no microphone audio.")
        }
    }
}
#endif
