import SwiftUI
import WebKit

/// The network map: everyone you have met, linked by what you talked about.
///
/// The backend already draws it (the dashboard it serves at `/`), with a
/// layout made for a phone, so the app shows that page here, full screen and
/// without browser controls, from the same address the rest of the app uses.
/// It needs no computer of yours to be on, only the backend.
struct MapView: View {
    @AppStorage(BackendAPI.baseURLKey) private var baseURL = BackendAPI.defaultBase
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
                BackendPage(url: url, reloads: reloads, loading: $loading, problem: $problem)
                    .opacity(problem == nil ? 1 : 0)
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

        init(_ parent: BackendPage) {
            self.parent = parent
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
            parent.problem = "\(error.localizedDescription) Check the address in Glasses › Backend."
            print("[thread] map failed to load: \(error.localizedDescription)")
        }
    }
}
