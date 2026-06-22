import SwiftUI
import WebKit

final class WebViewStore: ObservableObject {
    weak var webView: WKWebView?
    func reload() { webView?.reload() }
}

struct EditorTab: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var store = WebViewStore()

    var body: some View {
        NavigationStack {
            WebView(url: settings.editorURL, store: store)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Editor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { store.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                // Recreate the web view when the source URL changes (prod <-> beta).
                .id(settings.editorURL)
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let store: WebViewStore

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        store.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        store.webView = uiView
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}
