import SwiftUI
import WebKit

/// Hosts a received app's woven `client` island in a `WKWebView`, with the Host bridge injected
/// before any page script runs. This is the render target for an app that lives on a nexus — the
/// island runs client-side (wasm + DOM) on the phone, talking to the one `window.WB` surface.
struct AppHostView: UIViewRepresentable {
    let app: ReceivedApp
    let token: String

    func makeCoordinator() -> HostBridge { HostBridge(app: app, token: token) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        // Bridge installed at documentStart so the island sees `window.WB` immediately.
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "dock")
        controller.addUserScript(WKUserScript(
            source: context.coordinator.bootstrapJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: app.url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}

/// A received app on screen — the hosted island plus a thin chrome bar to get back to the pocket.
struct AppScreen: View {
    let app: ReceivedApp
    let token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppHostView(app: app, token: token)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(app.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Pocket", systemImage: "square.grid.2x2") }
                }
            }
    }
}
