import SwiftUI
import WebKit

struct EditorTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        NavigationStack {
            WebView(url: settings.editorURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Editor")
                .navigationBarTitleDisplayMode(.inline)
                // Recreate the web view when the source URL changes (prod <-> beta).
                .id(settings.editorURL)
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Pull-to-refresh: a UIRefreshControl on the web view's own scroll view.
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.handleRefresh(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }
    }
}
