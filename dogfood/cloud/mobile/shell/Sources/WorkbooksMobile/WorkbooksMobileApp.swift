import SwiftUI

/// Workbooks Mobile — the native iOS shell. A receiver for the apps published in the workspaces you
/// belong to: pair with your nexus(es), then everything in your pocket runs on the one Host surface.
@main
struct WorkbooksMobileApp: App {
    @StateObject private var account = Account()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(account)
        }
    }
}

/// Gate: pair first, then the pocket. Adding more nexuses happens from the launcher's gear menu.
struct RootView: View {
    @EnvironmentObject var account: Account

    var body: some View {
        if account.isPaired {
            LauncherView(account: account)
        } else {
            PairingView()
        }
    }
}
