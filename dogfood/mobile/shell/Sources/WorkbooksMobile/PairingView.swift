import SwiftUI

/// First-run / add-a-nexus screen. The user points the phone at a nexus endpoint and authorizes
/// with a session/PAT bearer; the shell mints a device token via `POST /mobile/pair`. Repeatable —
/// each pairing adds another nexus to the pool (one nexus per org).
struct PairingView: View {
    @EnvironmentObject var account: Account
    var onPaired: (() -> Void)?

    @State private var endpoint = "https://"
    @State private var authToken = ""
    @State private var deviceName = UIDevice.current.name
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nexus") {
                    TextField("https://your-nexus.workbooks.sh", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Authorize") {
                    SecureField("Access token (wbk_…)", text: $authToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("This device", text: $deviceName)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section {
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(account.isPaired ? "Add this nexus" : "Connect")
                        }
                    }
                    .disabled(busy || endpoint.isEmpty || authToken.isEmpty)
                }
            }
            .navigationTitle(account.isPaired ? "Add a nexus" : "Connect your account")
        }
    }

    private func pair() async {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)) else {
            error = "That doesn't look like a URL."; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await account.pair(baseURL: url, authToken: authToken, deviceName: deviceName)
            onPaired?()
        } catch {
            self.error = "Couldn't pair — check the endpoint and token."
        }
    }
}
