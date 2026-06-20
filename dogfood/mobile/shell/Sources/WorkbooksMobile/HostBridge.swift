import Foundation
import WebKit
import UIKit

/// The Dock membrane on the phone. A received app's `client` island talks to ONE Host surface
/// (`window.WB`); this bridge fulfils each capability from a provider:
///
///   • `local`   — iOS APIs (haptics, share sheet, clipboard, …) handled natively here.
///   • `runtime` — proxied to the originating nexus over HTTP/WS (the island already fetches the
///                 nexus directly with its Bearer; the bridge just supplies `base` + `token`).
///
/// Adding a capability means adding a case here — never a second contract the UI manages.
final class HostBridge: NSObject, WKScriptMessageHandlerWithReply {
    let app: ReceivedApp
    let token: String
    weak var presenter: UIViewController?

    init(app: ReceivedApp, token: String) {
        self.app = app
        self.token = token
    }

    /// The `window.WB` seam injected before the island runs: identity + a `call(cap, args)` that
    /// round-trips to the native local providers via the reply-capable message handler.
    var bootstrapJS: String {
        """
        window.WB = {
          base: "\(app.connection.baseURL.absoluteString)",
          token: "\(token)",
          app: { id: "\(app.id)", name: "\(jsEscape(app.name))" },
          nexus: { id: "\(app.connection.id)", name: "\(jsEscape(app.connection.name))" },
          // Local (iOS) capabilities — round-trip to native via the Dock message channel.
          call: (cap, args) => window.webkit.messageHandlers.dock.postMessage({ cap, args: args || {} }),
          // Sugar for the common ones.
          open: (a) => window.webkit.messageHandlers.dock.postMessage({ cap: "open", args: a }),
          haptic: () => window.webkit.messageHandlers.dock.postMessage({ cap: "haptic", args: {} }),
          share: (text) => window.webkit.messageHandlers.dock.postMessage({ cap: "share", args: { text } }),
        };
        """
    }

    // The local provider: resolve a capability call natively, return a JSON-able reply.
    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let cap = body["cap"] as? String else {
            replyHandler(nil, "malformed dock message"); return
        }
        let args = body["args"] as? [String: Any] ?? [:]

        switch cap {
        case "haptic":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            replyHandler(["ok": true], nil)

        case "clipboard.write":
            UIPasteboard.general.string = args["text"] as? String ?? ""
            replyHandler(["ok": true], nil)

        case "share":
            presentShare(args["text"] as? String ?? "")
            replyHandler(["ok": true], nil)

        default:
            // Unknown caps are a `runtime` concern — the island should fetch the nexus directly.
            replyHandler(nil, "unknown local cap: \(cap)")
        }
    }

    private func presentShare(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            self?.presenter?.present(vc, animated: true)
        }
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
