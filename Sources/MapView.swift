import SwiftUI
import WebKit

/// The network map: everyone you have met, linked by what you talked about.
///
/// The backend already draws it (the dashboard it serves at `/`), with a
/// layout made for a phone, so the app shows that page here, full screen and
/// without browser controls, from the same address the rest of the app uses.
/// It needs no computer of yours to be on, only the backend. When the
/// backend has a password, the page is given the one in Glasses › Backend.
struct MapView: View {
    @AppStorage(BackendAPI.baseURLKey) private var baseURL = BackendAPI.defaultBase
    @AppStorage(BackendPassword.changesKey) private var passwordChanges = 0
    @State private var reloads = 0
    @State private var loading = true
    @State private var problem: String?

    private var url: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.isEmpty ? BackendAPI.defaultBase : trimmed)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            if let url {
                BackendPage(url: url, reloads: reloads + passwordChanges, loading: $loading, problem: $problem)
                    .opacity(problem == nil ? 1 : 0)
                    // The map runs under the status bar and the glass tab bar,
                    // like Maps; the page keeps its controls clear of them with
                    // the safe-area insets. Not the keyboard's: that still
                    // shortens the page, so the ask field stays above it.
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            if let problem {
                ContentUnavailableView {
                    Label("Can't Reach the Backend", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try Again") { reload() }
                        .buttonStyle(.glass)
                }
            } else if loading {
                ProgressView()
            }
        }
        // A new address or password loads the page again, so clear what the
        // old one said.
        .onChange(of: baseURL) { problem = nil; loading = true }
        .onChange(of: passwordChanges) { problem = nil; loading = true }
    }

    private func reload() {
        problem = nil
        loading = true
        reloads += 1
    }
}

/// A WKWebView showing one page of the backend, reloaded when `reloads`
/// changes, and reporting whether it loaded.
private struct BackendPage: UIViewRepresentable {
    let url: URL
    let reloads: Int
    @Binding var loading: Bool
    @Binding var problem: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.allowsBackForwardNavigationGestures = false
        // The page fills the view and scrolls nothing itself; the safe areas
        // are SwiftUI's to handle.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        context.coordinator.watchKeyboard(of: view)
        context.coordinator.load(url, in: view, reloads: reloads)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(url, in: view, reloads: reloads)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BackendPage
        private var loadedURL: URL?
        private var loadedReloads = -1

        private var keyboardHidden: NSObjectProtocol?

        init(_ parent: BackendPage) {
            self.parent = parent
        }

        deinit {
            if let keyboardHidden { NotificationCenter.default.removeObserver(keyboardHidden) }
        }

        /// While the keyboard is up, WebKit scrolls the page to keep the ask
        /// field in sight, and doesn't always scroll it back. When the keyboard
        /// has gone, put the page back where it belongs.
        func watchKeyboard(of view: WKWebView) {
            keyboardHidden = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
            ) { [weak view] _ in
                guard let scroll = view?.scrollView else { return }
                if scroll.zoomScale != 1 { scroll.setZoomScale(1, animated: true) }
                if scroll.contentOffset != .zero { scroll.setContentOffset(.zero, animated: true) }
            }
        }

        /// Loads only when the address or the reload count changed.
        func load(_ url: URL, in view: WKWebView, reloads: Int) {
            guard url != loadedURL || reloads != loadedReloads else { return }
            loadedURL = url
            loadedReloads = reloads
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            view.load(request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.problem = nil
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        /// The backend asks for its password: give it the one in Glasses ›
        /// Backend, unless that one was just turned down.
        func webView(
            _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
                  space.host == loadedURL?.host()
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let password = BackendPassword.value
            let turnedDown = challenge.previousFailureCount > 0
                && challenge.proposedCredential?.password == password
            guard !password.isEmpty, !turnedDown else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                parent.loading = false
                parent.problem = password.isEmpty
                    ? "This backend needs a password. Enter it in Glasses › Backend."
                    : "The backend didn't accept the password in Glasses › Backend."
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: BackendPassword.user, password: password, persistence: .forSession)
            )
        }

        /// Links that lead off the backend open in Safari, not in the map.
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated, let target = action.request.url,
               target.host() != loadedURL?.host()
            {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func fail(_ error: Error) {
            let code = (error as NSError).code
            guard code != NSURLErrorCancelled else { return }
            parent.loading = false
            // A turned-down password has already said so.
            guard parent.problem == nil else { return }
            parent.problem = "\(error.localizedDescription) Check the address in Glasses › Backend."
            print("[thread] map failed to load: \(error.localizedDescription)")
        }
    }
}
