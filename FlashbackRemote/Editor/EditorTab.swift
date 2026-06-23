import SwiftUI
import WebKit

struct EditorTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        // No nav bar — the web editor has its own chrome. A fixed bottom spacer
        // (the height of the floating tab bar) keeps the editor's effects/export
        // controls visible above it.
        VStack(spacing: 0) {
            WebView(url: settings.editorURL)
                .ignoresSafeArea(edges: .top)
                .id(settings.editorURL)
            Color.clear.frame(height: 64)
        }
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
