import SwiftUI

/// First-run / add-a-nexus screen. The user points the phone at a nexus and signs in with the
/// nexus's OWN auth (the same native login + OAuth providers the cloud dashboard dogfoods), opened in
/// a system web-auth session. On success the nexus hands back a device token and the connection is
/// stored. Repeatable — each sign-in adds another nexus to the pool (one nexus per org).
struct PairingView: View {
    @EnvironmentObject var account: Account
    var onPaired: (() -> Void)?

    @State private var endpoint = "https://"
    @State private var busy = false
    @State private var error: String?
    @State private var showAdvanced = false
    @State private var pastedToken = ""

    private let web = WebAuth()

    var body: some View {
        NavigationStack {
            Form {
                Section("Nexus") {
                    TextField("https://your-nexus.workbooks.sh", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(account.isPaired ? "Add a nexus" : "Sign in")
                        }
                    }
                    .disabled(busy || baseURL == nil)
                } footer: {
                    Text("Opens your nexus's sign-in — email or your team's SSO — then returns to the app.")
                }

                Section {
                    DisclosureGroup("Advanced: paste a token", isExpanded: $showAdvanced) {
                        SecureField("Access token (wbk_…)", text: $pastedToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect with token") { Task { await connectWithToken() } }
                            .disabled(busy || pastedToken.isEmpty || baseURL == nil)
                    }
                }
            }
            .navigationTitle(account.isPaired ? "Add a nexus" : "Connect your account")
        }
    }

    private var baseURL: URL? {
        URL(string: endpoint.trimmingCharacters(in: .whitespaces)).flatMap {
            ($0.scheme == "https" || $0.scheme == "http") && $0.host != nil ? $0 : nil
        }
    }

    private func signIn() async {
        guard let url = baseURL else { error = "That doesn't look like a URL."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let r = try await web.signIn(nexusURL: url)
            account.connect(baseURL: url, token: r.token, deviceID: r.deviceID, nexus: r.nexus)
            onPaired?()
        } catch is CancellationError {
            // user dismissed — no error
        } catch {
            self.error = "Sign-in didn't complete."
        }
    }

    private func connectWithToken() async {
        guard let url = baseURL else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await account.pair(baseURL: url, authToken: pastedToken, deviceName: "iPhone")
            onPaired?()
        } catch {
            self.error = "Couldn't connect with that token."
        }
    }
}
