import Foundation
import Security

/// One paired nexus: a `runtime` endpoint + the device-scoped token that authenticates to it.
/// A user may belong to several orgs, so the account holds many of these (one per org / nexus).
struct NexusConnection: Codable, Identifiable, Hashable {
    var id: String          // nexus id (one per org)
    var name: String        // friendly name
    var emoji: String
    var baseURL: URL        // the runtime endpoint
    var deviceID: String    // the minted token's id (for unpair/revoke)
    // The plaintext token is NEVER stored in this struct — it lives in the Keychain, keyed by `id`.
}

/// The account: the set of nexuses this phone is paired with. Connections persist in
/// UserDefaults (non-secret), tokens persist in the Keychain (secret). This is the only place
/// that knows how to reach a `runtime` provider, so the rest of the app stays endpoint-agnostic.
@MainActor
final class Account: ObservableObject {
    @Published private(set) var connections: [NexusConnection] = []

    private let store = UserDefaults.standard
    private let key = "wb.connections"

    init() { load() }

    var isPaired: Bool { !connections.isEmpty }

    /// Pair with a nexus at `baseURL` using a session/login bearer that authorizes the mint.
    /// Calls `POST /mobile/pair`, stores the returned device token in the Keychain.
    func pair(baseURL: URL, authToken: String, deviceName: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("mobile/pair"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": deviceName, "platform": "ios",
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WBError.pairFailed
        }
        let paired = try JSONDecoder().decode(PairResponse.self, from: data)

        let conn = NexusConnection(
            id: paired.nexus.id, name: paired.nexus.name, emoji: paired.nexus.emoji,
            baseURL: baseURL, deviceID: paired.deviceID
        )
        Keychain.set(paired.token, account: conn.id)
        connections.removeAll { $0.id == conn.id }
        connections.append(conn)
        save()
    }

    func token(for conn: NexusConnection) -> String? { Keychain.get(account: conn.id) }

    func unpair(_ conn: NexusConnection) {
        Keychain.delete(account: conn.id)
        connections.removeAll { $0.id == conn.id }
        save()
    }

    private func load() {
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NexusConnection].self, from: data)
        else { return }
        connections = decoded
    }

    private func save() {
        store.set(try? JSONEncoder().encode(connections), forKey: key)
    }
}

struct PairResponse: Decodable {
    let token: String
    let deviceID: String
    let nexus: NexusView
    enum CodingKeys: String, CodingKey { case token, deviceID = "device_id", nexus }
}

struct NexusView: Decodable, Hashable {
    let id: String
    let name: String
    let emoji: String
}

enum WBError: Error { case pairFailed, badResponse }

/// Minimal Keychain wrapper — device tokens at rest in the secure enclave, never in plaintext defaults.
enum Keychain {
    private static let service = "sh.workbooks.mobile.token"

    static func set(_ value: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
