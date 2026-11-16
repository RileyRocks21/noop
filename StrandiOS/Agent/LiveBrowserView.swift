#if os(iOS)
import SwiftUI
import StrandDesign
import WebKit

// MARK: - Live Browser (minimal)
//
// A WKWebView wrapper that shows the agent's noVNC session (auth-request liveViewUrl) so you can
// watch — and take over — while the agent logs into a site on your behalf. Step 4 grows this into
// the full Live Browser activity surface; this is the minimal sheet Settings links to.

struct LiveBrowserView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LiveBrowserWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }
}

private struct LiveBrowserWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url { webView.load(URLRequest(url: url)) }
    }
}
#endif
