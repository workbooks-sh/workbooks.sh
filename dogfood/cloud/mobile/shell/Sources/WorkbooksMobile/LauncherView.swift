import SwiftUI

/// The native pocket-of-apps grid — the same surface as the `.work` launcher island, drawn natively
/// off `/mobile/apps`. Pools every paired nexus; tapping a tile opens the received app.
struct LauncherView: View {
    @EnvironmentObject var account: Account
    @StateObject private var catalog: Catalog
    @State private var selected: ReceivedApp?

    init(account: Account) {
        _catalog = StateObject(wrappedValue: Catalog(account: account))
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if catalog.apps.isEmpty && !catalog.loading {
                    ContentUnavailableView(
                        "Nothing in your pocket yet",
                        systemImage: "tray",
                        description: Text("Apps published to a workspace you're in land here.")
                    )
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(catalog.apps) { app in
                            Button { selected = app } label: { Tile(app: app) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
            }
            .background(Color(red: 0.97, green: 0.965, blue: 0.945))
            .navigationTitle("In your pocket")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let first = account.connections.first {
                        NavigationLink {
                            AgentChatView(nexus: first)
                        } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(account.connections) { c in
                            Button(role: .destructive) { account.unpair(c); Task { await catalog.refresh() } } label: {
                                Label("Unpair \(c.emoji) \(c.name)", systemImage: "minus.circle")
                            }
                        }
                    } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await catalog.refresh() }
            .task { await catalog.refresh() }
            .navigationDestination(item: $selected) { app in
                if let token = account.token(for: app.connection) {
                    AppScreen(app: app, token: token)
                }
            }
        }
    }
}

private struct Tile: View {
    let app: ReceivedApp
    var body: some View {
        VStack(spacing: 9) {
            Text(app.icon)
                .font(.system(size: 32))
                .frame(width: 68, height: 68)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 9, y: 4)
            Text(app.name)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: 92)
    }
}
