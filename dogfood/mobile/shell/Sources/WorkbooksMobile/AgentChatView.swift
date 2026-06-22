import SwiftUI

// MARK: - MOCK (preview only)
// Chat-with-your-agents is not wired yet — agents deployed to a nexus aren't exposed over a mobile
// chat seam. This view is a deliberate mock so the surface exists and the design is settled; replies
// are canned. When the agent transport lands (a `server`/agent brain block + an RCP chat endpoint),
// swap `MockAgentTransport` for the real client. Tracked: bd wb-if6z.

struct AgentMessage: Identifiable, Hashable {
    enum Role { case user, agent }
    let id = UUID()
    let role: Role
    let text: String
}

/// Stand-in for the future RCP agent stream. Returns canned, clearly-fake replies.
@MainActor
enum MockAgentTransport {
    static func reply(to prompt: String) async -> String {
        try? await Task.sleep(for: .milliseconds(450))
        return "🧪 (mock) I'd help with “\(prompt.prefix(60))”, but the agent transport isn't wired yet. "
            + "Once your nexus exposes its agents over RCP, this becomes a real conversation."
    }
}

struct AgentChatView: View {
    let nexus: NexusConnection
    @State private var input = ""
    @State private var messages: [AgentMessage] = [
        .init(role: .agent, text: "Hi — I'm a preview of your nexus agent. This chat is mocked for now.")
    ]
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            MockBanner()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { m in Bubble(message: m).id(m.id) }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(Color(red: 0.97, green: 0.965, blue: 0.945))
        .navigationTitle("\(nexus.emoji) Agent")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message your agent…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(Color(white: 0.9)))
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || sending)
        }
        .padding(12)
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messages.append(.init(role: .user, text: text))
        input = ""; sending = true
        let reply = await MockAgentTransport.reply(to: text)
        messages.append(.init(role: .agent, text: reply))
        sending = false
    }
}

private struct Bubble: View {
    let message: AgentMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(message.role == .user ? Color(red: 0.10, green: 0.11, blue: 0.12) : .white,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(message.role == .user ? .clear : Color(white: 0.9))
                )
            if message.role == .agent { Spacer(minLength: 40) }
        }
    }
}

/// Honest "this is a preview" banner — never let a mock masquerade as shipped.
struct MockBanner: View {
    var text = "Preview — agent chat is mocked, not yet connected"
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(red: 0.95, green: 0.86, blue: 0.64).opacity(0.5))
    }
}
