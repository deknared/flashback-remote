import SwiftUI
import WebKit

struct EditorTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        WebView(url: settings.editorURL)
            .ignoresSafeArea()
            // Recreate the web view when the source URL changes (prod <-> staging).
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
