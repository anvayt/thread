import MWDATCore
import SwiftUI

/// Surfaces the DAT bootstrap error in the UI instead of swallowing it.
enum DATBootstrap {
    nonisolated(unsafe) static var error: String?
}

@main
struct ThreadApp: App {
    @StateObject private var glasses = GlassesManager()
    @StateObject private var speech = SpeechManager()

    init() {
        do {
            try Wearables.configure()
        } catch {
            DATBootstrap.error = "\(error)"
            print("Wearables.configure failed: \(error)")
        }
        #if DEBUG
        SimulatedGlasses.startIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(glasses)
                .environmentObject(speech)
                .onOpenURL { url in
                    // Return leg of DAT registration via our URL scheme.
                    guard
                        let components = URLComponents(
                            url: url, resolvingAgainstBaseURL: false
                        ),
                        components.queryItems?.contains(where: {
                            $0.name == "metaWearablesAction"
                        }) == true
                    else { return }
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
        }
    }
}

/// The app's tabs, in order. The simulated glasses' `tab N` command uses the
/// raw values.
enum AppTab: Int, Hashable {
    case meet, people, glasses, search
}

struct RootView: View {
    @EnvironmentObject private var glasses: GlassesManager
    @EnvironmentObject private var speech: SpeechManager
    @ObservedObject private var engine = MeetEngine.shared
    @StateObject private var search = SearchModel()
    @AppStorage(WelcomeView.seenKey) private var hasSeenWelcome = false
    @State private var tab: AppTab = .meet
    @State private var bootstrapped = false

    /// A Meet pass is running, or Keep Going is on.
    private var meetIsActive: Bool {
        engine.phase.isBusy || engine.autoRepeat
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Meet", systemImage: "person.wave.2", value: AppTab.meet) {
                MeetView()
            }
            Tab("People", systemImage: "person.2", value: AppTab.people) {
                PeopleView()
            }
            Tab("Glasses", systemImage: "eyeglasses", value: AppTab.glasses) {
                GlassesView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView(model: search)
            }
        }
        // Choosing the Search tab opens its search field straight away.
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
        // A pass that is running while another tab is open shows above the
        // tab bar, with Done to end it from there.
        .modifier(MeetAccessoryModifier(isEnabled: meetIsActive && tab != .meet) { tab = .meet })
        .sheet(
            isPresented: Binding(
                get: { bootstrapped && !hasSeenWelcome },
                set: { if !$0 { hasSeenWelcome = true } }
            ),
            onDismiss: {
                Task { await prepareMicrophone() }
            }
        ) {
            WelcomeView { hasSeenWelcome = true }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            glasses.configure()
            MeetEngine.shared.bind(glasses: glasses, speech: speech)

            // Audio session first, then permissions, then the mic engine.
            // Doing this at launch means a denied permission shows up in the
            // UI now, not the first time the button is pressed. On the very
            // first launch it waits for the welcome sheet to close.
            if hasSeenWelcome {
                await prepareMicrophone()
            }
            #if DEBUG
            await SimulatedGlasses.followCommands(glasses: glasses)
            #endif
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: SimulatedGlasses.selectTab)) {
            tab = ($0.object as? Int).flatMap(AppTab.init(rawValue:)) ?? tab
        }
        #endif
    }

    private func prepareMicrophone() async {
        AudioSessionController.shared.activate()
        await DictationManager.shared.requestAuthorization()
        DictationManager.shared.prime()
        await DictationManager.shared.refreshHintNames()
    }
}

/// Shows `MeetAccessory` above the tab bar. Hiding the accessory needs iOS
/// 26.1; on 26.0 there is none.
private struct MeetAccessoryModifier: ViewModifier {
    let isEnabled: Bool
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                MeetAccessory(onOpen: onOpen)
            }
        } else {
            content
        }
    }
}
