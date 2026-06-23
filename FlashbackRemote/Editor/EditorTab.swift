import SwiftUI
import WebKit

struct EditorTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        // No nav bar — the web editor has its own chrome. We only ignore the top
        // safe area; the bottom keeps the tab-bar inset so the editor's effects /
        // export controls sit above the floating tab bar.
        WebView(url: settings.editorURL)
            .ignoresSafeArea(edges: .top)
            .id(settings.editorURL)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}
