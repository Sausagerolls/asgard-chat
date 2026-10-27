import AsgardKit
import SwiftUI

/// First run: connect to a server, then create an account, sign in or link
/// this Mac to an existing device.
struct MacOnboarding: View {
    @Environment(ChatEngine.self) private var engine
    enum Mode: String, CaseIterable, Identifiable { case signUp = "Create Account", signIn = "Sign In", link = "Link Device"; var id: String { rawValue } }

    @State private var server = AppGroup.defaults.string(forKey: "lastServer") ?? "https://chat.giantmushroom.studio"
    @State private var info: ServerInfo?
    @State private var mode: Mode = .signIn
    @State private var invite = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var linkCode = ""
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: 48) {
                VStack(alignment: .leading, spacing: 16) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 96)
                    Text("Asgard").font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("Private messaging on a server you own.\nEnd-to-end encrypted, always.").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Messages, calls and files are encrypted on your Mac", systemImage: "lock.shield")
                        Label("Your server, your rules, your data", systemImage: "server.rack")
                        Label("Drop into voice rooms from any group", systemImage: "speaker.wave.2")
                    }
                    .padding(.top, 8)
                    Button("Explore the Demo") { engine.enterDemo() }.buttonStyle(.link).padding(.top, 8)
                }
                .frame(maxWidth: 360)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Your server").font(.headline)
                    HStack {
                        TextField("https://chat.example.com", text: $server).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await check() } }
                        Button("Connect") { Task { await check() } }.disabled(working)
                    }
                    if let info {
                        Label("\(info.name) · Asgard \(info.version)", systemImage: "checkmark.seal.fill").foregroundStyle(Brand.teal).font(.callout)
                        Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden()
                        Group {
                            switch mode {
                            case .signUp:
                                TextField("Invite code", text: $invite)
                                TextField("Username", text: $username)
                                TextField("Display name", text: $displayName)
                                SecureField("Password (10+ characters)", text: $password)
                            case .signIn:
                                TextField("Username", text: $username)
                                SecureField("Password", text: $password)
                                Text("Signing in adds this Mac as a new device. Older messages can't be decrypted here; link from your iPhone instead to keep them in sync going forward.")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .link:
                                Text("On your iPhone: Settings › Devices › Link a device. Hold the QR code up to this Mac's camera, or type the code under it.")
                                    .font(.callout).foregroundStyle(.secondary)
                                if scanning {
                                    MacQRScanner { payload in handleScan(payload) }
                                        .frame(height: 220)
                                        .clipShape(.rect(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.bifrost, lineWidth: 3))
                                } else {
                                    Button { scanning = true } label: { Label("Scan with Camera", systemImage: "camera.viewfinder").frame(maxWidth: .infinity) }
                                        .controlSize(.large)
                                }
                                TextField("XXXX-XXXX-XXXX-XXXX", text: $linkCode).font(.body.monospaced())
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button { Task { await submit() } } label: {
                            Text(mode.rawValue).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !valid)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    if working { ProgressView().controlSize(.small) }
                }
                .padding(28)
                .frame(width: 380)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
            }
            .padding(40)
        }
        .task { await check() }
    }

    /// Payload is asgard://link?host=<host>&code=<code>.
    func handleScan(_ payload: String) {
        guard let url = URL(string: payload), url.scheme == "asgard",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { error = "That isn't an Asgard link code."; return }
        scanning = false
        linkCode = code
        if let host = items.first(where: { $0.name == "host" })?.value, serverURL?.host() != host {
            server = (serverURL?.scheme ?? "https") + "://" + host
        }
        Task { await submit() }
    }

    var valid: Bool {
        switch mode {
        case .signUp: !invite.isEmpty && username.count >= 3 && password.count >= 10
        case .signIn: !username.isEmpty && !password.isEmpty
        case .link: linkCode.count >= 8
        }
    }

    var serverURL: URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }

    func check() async {
        guard let url = serverURL else { error = "That isn't a valid address."; return }
        working = true
        defer { working = false }
        do {
            info = try await APIClient(baseURL: url, token: nil).info()
            server = url.absoluteString
            AppGroup.defaults.set(server, forKey: "lastServer")
            error = nil
        } catch {
            info = nil
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    func submit() async {
        guard let url = serverURL else { return }
        working = true
        error = nil
        defer { working = false }
        let device = Host.current().localizedName ?? "Mac"
        do {
            switch mode {
            case .signUp:
                try await engine.signUp(server: url, invite: invite.trimmingCharacters(in: .whitespaces), username: username,
                                        displayName: displayName.isEmpty ? username : displayName, password: password, deviceName: device)
            case .signIn:
                try await engine.signIn(server: url, username: username, password: password, deviceName: device)
            case .link:
                try await engine.claimDeviceLink(server: url, code: linkCode.trimmingCharacters(in: .whitespaces).uppercased(), deviceName: device)
            }
            MacNotifications.requestAndRegister()
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
