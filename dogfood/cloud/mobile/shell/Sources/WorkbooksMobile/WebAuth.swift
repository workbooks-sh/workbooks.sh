import AuthenticationServices
import UIKit

/// The native SSO bridge. Dogfoods the nexus's OWN auth: opens `/mobile/connect` (the same
/// `Nexus.Auth.Native` + OAuth providers the cloud dashboard uses) in a system web-auth session,
/// and captures the device token the page hands back via the `workbooks-auth://callback#…` redirect.
/// No credentials ever touch the app — only the resulting `wbk_` token does.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let scheme = "workbooks-auth"

    struct Result {
        let token: String
        let deviceID: String
        let nexus: NexusView
    }

    func signIn(nexusURL: URL) async throws -> Result {
        let start = nexusURL
            .appendingPathComponent("mobile/connect")
            .appending(queryItems: [URLQueryItem(name: "cb", value: "\(Self.scheme)://callback")])

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: start, callbackURLScheme: Self.scheme
            ) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? WBError.pairFailed) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        return try parse(callback)
    }

    // workbooks-auth://callback#token=…&device_id=…&nexus_id=…&name=…&emoji=…
    private func parse(_ url: URL) throws -> Result {
        var pairs: [String: String] = [:]
        for kv in (url.fragment ?? "").split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1)
            if p.count == 2 {
                pairs[String(p[0])] = String(p[1]).removingPercentEncoding ?? String(p[1])
            }
        }
        guard let token = pairs["token"], !token.isEmpty,
              let nid = pairs["nexus_id"] else { throw WBError.pairFailed }

        return Result(
            token: token,
            deviceID: pairs["device_id"] ?? "",
            nexus: NexusView(id: nid, name: pairs["name"] ?? "Nexus", emoji: pairs["emoji"] ?? "")
        )
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
