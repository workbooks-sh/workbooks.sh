import Foundation

/// One launchable app received from a nexus. `path` is the mount the woven `client` island loads
/// from; `connection` carries the originating nexus so the host can point `runtime` caps back at it.
struct ReceivedApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let path: String
    let updated: Int
    let connection: NexusConnection

    /// Absolute URL of the app surface on its originating nexus.
    var url: URL { connection.baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" }))) }
}

private struct AppsResponse: Decodable {
    struct Tile: Decodable { let id, name, icon, path: String; let updated: Int }
    let apps: [Tile]
}

/// Fetches and pools the catalog across every paired nexus — the launcher shows one grid even when
/// the user belongs to several orgs. Each nexus is queried with its own device token.
@MainActor
final class Catalog: ObservableObject {
    @Published private(set) var apps: [ReceivedApp] = []
    @Published private(set) var loading = false

    private let account: Account
    init(account: Account) { self.account = account }

    func refresh() async {
        loading = true
        defer { loading = false }

        var pooled: [ReceivedApp] = []
        for conn in account.connections {
            guard let token = account.token(for: conn) else { continue }
            do {
                pooled += try await fetch(conn, token: token)
            } catch {
                // A single unreachable nexus must not blank the whole pocket — skip it.
                continue
            }
        }
        apps = pooled.sorted { $0.name < $1.name }
    }

    private func fetch(_ conn: NexusConnection, token: String) async throws -> [ReceivedApp] {
        var req = URLRequest(url: conn.baseURL.appendingPathComponent("mobile/apps"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WBError.badResponse
        }
        let decoded = try JSONDecoder().decode(AppsResponse.self, from: data)
        return decoded.apps.map {
            ReceivedApp(id: "\(conn.id):\($0.id)", name: $0.name, icon: $0.icon,
                        path: $0.path, updated: $0.updated, connection: conn)
        }
    }
}
