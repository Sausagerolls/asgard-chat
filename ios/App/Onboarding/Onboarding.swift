import AsgardKit
import SwiftUI

struct OnboardingFlow: View {
    enum Step: Hashable { case server, signUp, signIn, link }
    @State private var path: [Step] = []
    @State private var server = AppGroup.defaults.string(forKey: "lastServer") ?? "https://chat.giantmushroom.studio"
    @State private var info: ServerInfo?
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(path: $path)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .server: ServerView(server: $server, info: $info, path: $path)
                    case .signUp: SignUpView(server: server, info: info)
                    case .signIn: SignInView(server: server)
                    case .link: LinkDeviceScanView(server: server)
                    }
                }
        }
        .onChange(of: router.pendingInvite) { _, code in
            if code != nil { path = [.server, .signUp] }
        }
        .onAppear {
            if router.pendingInvite != nil { path = [.server, .signUp] }
        }
    }
}

struct WelcomeView: View {
    @Binding var path: [OnboardingFlow.Step]
    @Environment(ChatEngine.self) private var engine
    @State private var appeared = false

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                Spacer()
                Image("BrandMark").resizable().scaledToFit().frame(width: 150)
                    .shadow(color: Brand.violet.opacity(0.6), radius: 40)
                    .scaleEffect(appeared ? 1 : 0.8).opacity(appeared ? 1 : 0)
                Text("Asgard").font(.system(size: 46, weight: .bold, design: .rounded)).padding(.top, 8)
                Text("Private messaging on a server you own.\nEnd-to-end encrypted, always.")
                    .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
                VStack(spacing: 14) {
                    FeatureLine(icon: "lock.shield.fill", text: "Messages, calls and media are encrypted on your device")
                    FeatureLine(icon: "server.rack", text: "Your server, your rules, your data")
                    FeatureLine(icon: "sparkles", text: "Apple Intelligence runs on-device only")
                }
                .glassCard()
                .padding(.horizontal, 20)
                Spacer()
                VStack(spacing: 12) {
                    Button { path.append(.server) } label: {
                        Text("Get started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    Button("Explore the demo") { withAnimation { engine.enterDemo() } }
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.35).delay(0.1)) { appeared = true } }
    }
}

struct FeatureLine: View {
    var icon: String
    var text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Brand.aurora).frame(width: 30)
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ServerView: View {
    @Binding var server: String
    @Binding var info: ServerInfo?
    @Binding var path: [OnboardingFlow.Step]
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("https://chat.example.com", text: $server)
                    .textContentType(.URL).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onSubmit { Task { await check() } }
            } header: {
                Text("Your server")
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
                else if let info {
                    Label("\(info.name) · Asgard \(info.version)", systemImage: "checkmark.seal.fill").foregroundStyle(Brand.teal)
                } else {
                    Text("The address your server admin gave you.")
                }
            }
            if info != nil {
                Section {
                    Button { path.append(.signUp) } label: { Label("Create an account", systemImage: "person.badge.plus") }
                    Button { path.append(.signIn) } label: { Label("Sign in", systemImage: "person.crop.circle") }
                    Button { path.append(.link) } label: { Label("Link to another device", systemImage: "qrcode.viewfinder") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground(intensity: 0.5))
        .navigationTitle("Connect")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Check") { Task { await check() } }.disabled(checking)
            }
        }
        .task { if info == nil { await check() } }
        .overlay { if checking { ProgressView() } }
    }

    func check() async {
        error = nil
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { error = "That isn't a valid address."; return }
        server = s
        checking = true
        defer { checking = false }
        do {
            info = try await APIClient(baseURL: url, token: nil).info()
            AppGroup.defaults.set(s, forKey: "lastServer")
        } catch {
            info = nil
            self.error = "Couldn't reach an Asgard server there. \((error as? APIError)?.message ?? error.localizedDescription)"
        }
    }
}

struct SignUpView: View {
    let server: String
    let info: ServerInfo?
    @Environment(ChatEngine.self) private var engine
    @Environment(Router.self) private var router
    @State private var invite = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            if info?.openRegistration != true || !invite.isEmpty {
                Section("Invite") {
                    TextField("XXXX-XXXX-XXXX", text: $invite).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            }
            Section {
                TextField("Name", text: $displayName).textContentType(.name)
                TextField("username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password (10+ characters)", text: $password).textContentType(.newPassword)
            } header: { Text("You") } footer: {
                Text("Your username is how friends on this server find you. Your password never leaves the server in plain text, and your message keys never leave this device.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button { Task { await submit() } } label: {
                    HStack { Spacer(); if working { ProgressView() } else { Text("Create account").bold() }; Spacer() }
                }
                .disabled(working || username.count < 3 || password.count < 10)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground(intensity: 0.5))
        .navigationTitle("Create account")
        .onAppear { if let code = router.pendingInvite { invite = code; router.pendingInvite = nil } }
    }

    func submit() async {
        guard let url = URL(string: server) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await engine.signUp(server: url, invite: invite, username: username, displayName: displayName.isEmpty ? username : displayName,
                                    password: password, deviceName: UIDevice.current.name)
            PushRegistrar.shared.register()
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}

struct SignInView: View {
    let server: String
    @Environment(ChatEngine.self) private var engine
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
            } footer: {
                Text("Signing in adds this iPhone as a new device. Messages sent before now can't be decrypted here — link from an existing device to bring your history.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button { Task { await submit() } } label: {
                    HStack { Spacer(); if working { ProgressView() } else { Text("Sign in").bold() }; Spacer() }
                }
                .disabled(working || username.isEmpty || password.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground(intensity: 0.5))
        .navigationTitle("Sign in")
    }

    func submit() async {
        guard let url = URL(string: server) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await engine.signIn(server: url, username: username, password: password, deviceName: UIDevice.current.name)
            PushRegistrar.shared.register()
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
