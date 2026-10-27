import AsgardKit
import SwiftUI

/// In-app server administration (mirrors the web panel at /admin).
struct AdminView: View {
    @Environment(ChatEngine.self) private var engine
    @State private var stats: AdminStats?
    @State private var users: [AdminUser] = []
    @State private var invites: [Invite] = []
    @State private var newInvite: Invite?
    @State private var tempPassword: String?
    @State private var showCreate = false

    var body: some View {
        List {
            if let s = stats {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                        StatTile(value: "\(s.users)", label: "Users")
                        StatTile(value: "\(s.onlineUsers)", label: "Online")
                        StatTile(value: "\(s.conversations)", label: "Chats")
                        StatTile(value: "\(s.messages)", label: "Messages")
                        StatTile(value: ByteCountFormatter.string(fromByteCount: s.mediaBytes, countStyle: .file), label: "Media")
                        StatTile(value: ByteCountFormatter.string(fromByteCount: s.databaseBytes, countStyle: .file), label: "Database")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    LabeledContent("Push", value: s.pushEnabled ? "Configured" : "Not configured")
                    LabeledContent("Calls", value: s.callsEnabled ? "Configured" : "Not configured")
                    LabeledContent("Server version", value: s.version)
                }
            } else if engine.isDemo {
                Section { Text("Admin tools need a real server.").foregroundStyle(.secondary) }
            }
            Section {
                Button { showCreate = true } label: { Label("Create invite", systemImage: "envelope.badge.person.crop") }
                ForEach(invites) { inv in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(inv.code).font(.body.monospaced().bold())
                            if inv.makeAdmin { Text("ADMIN").font(.caption2.bold()).foregroundStyle(Brand.gold) }
                            Spacer()
                            Text("\(inv.uses)/\(inv.maxUses)").foregroundStyle(.secondary)
                        }
                        if !inv.note.isEmpty { Text(inv.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    .contextMenu {
                        ShareLink(item: URL(string: inv.url)!) { Label("Share link", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.string = inv.code } label: { Label("Copy code", systemImage: "doc.on.doc") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { try? await engine.api?.call("DELETE", "/admin/invites/\(inv.code)"); await load() } } label: { Label("Revoke", systemImage: "trash") }
                    }
                }
            } header: { Text("Invites") }
            Section("Users") {
                ForEach(users) { u in
                    HStack {
                        AvatarView(id: u.id, name: u.displayName, size: 36, online: u.online)
                        VStack(alignment: .leading) {
                            HStack {
                                Text(u.displayName).font(.headline)
                                if u.isAdmin { Image(systemName: "crown.fill").foregroundStyle(Brand.gold).font(.caption) }
                                if u.isBot { Text("BOT").font(.caption2.bold()) }
                                if u.disabled { Text("DISABLED").font(.caption2.bold()).foregroundStyle(.red) }
                            }
                            Text("@\(u.username) · \(u.deviceCount) devices · \(ByteCountFormatter.string(fromByteCount: u.storageUsed, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { userMenu(u) }
                }
            }
        }
        .navigationTitle("Server admin")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showCreate) { CreateInviteSheet { inv in newInvite = inv; Task { await load() } } }
        .sheet(item: $newInvite) { inv in InviteShareSheet(invite: inv) }
        .alert("Temporary password", isPresented: Binding(get: { tempPassword != nil }, set: { if !$0 { tempPassword = nil } })) {
            Button("Copy") { UIPasteboard.general.string = tempPassword }
            Button("Done", role: .cancel) {}
        } message: { Text(tempPassword ?? "") }
    }

    @ViewBuilder func userMenu(_ u: AdminUser) -> some View {
        if u.id != engine.myID {
            Button { patch(u, ["is_admin": .bool(!u.isAdmin)]) } label: { Label(u.isAdmin ? "Remove admin" : "Make admin", systemImage: "crown") }
            Button { patch(u, ["disabled": .bool(!u.disabled)]) } label: { Label(u.disabled ? "Enable" : "Disable", systemImage: "nosign") }
            if !u.isBot {
                Button {
                    Task {
                        nonisolated struct R: Decodable, Sendable { var temporary_password: String }
                        if let r: R = try? await engine.api?.send("POST", "/admin/users/\(u.id.lower)/reset-password") { tempPassword = r.temporary_password }
                    }
                } label: { Label("Reset password", systemImage: "key") }
            }
            Button(role: .destructive) { Task { try? await engine.api?.call("DELETE", "/admin/users/\(u.id.lower)"); await load() } } label: { Label("Delete user", systemImage: "trash") }
        }
    }

    func patch(_ u: AdminUser, _ body: [String: JSONValue]) {
        Task { try? await engine.api?.call("PATCH", "/admin/users/\(u.id.lower)", body: body); await load() }
    }

    func load() async {
        guard let api = engine.api else { return }
        stats = try? await api.send("GET", "/admin/stats")
        users = (try? await api.send("GET", "/admin/users")) ?? []
        invites = (try? await api.send("GET", "/admin/invites")) ?? []
    }
}

struct StatTile: View {
    let value: String, label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct CreateInviteSheet: View {
    var onCreated: (Invite) -> Void
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var uses = 1
    @State private var hours = 168
    @State private var admin = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Note (e.g. For Mum)", text: $note)
                Stepper("Uses: \(uses)", value: $uses, in: 1...100)
                Picker("Expires", selection: $hours) { Text("1 day").tag(24); Text("1 week").tag(168); Text("30 days").tag(720); Text("Never").tag(0) }
                Toggle("Make admin", isOn: $admin)
            }
            .navigationTitle("New invite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            nonisolated struct Body: Encodable, Sendable { var note: String; var max_uses: Int; var expires_hours: Int; var make_admin: Bool }
                            if let inv: Invite = try? await engine.api?.send("POST", "/admin/invites", body: Body(note: note, max_uses: uses, expires_hours: hours, make_admin: admin)) {
                                dismiss()
                                onCreated(inv)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct InviteShareSheet: View {
    let invite: Invite
    var body: some View {
        VStack(spacing: 18) {
            Text("Invite ready").font(.title2.bold())
            if let img = QRCode.image(invite.url) {
                Image(uiImage: img).interpolation(.none).resizable().frame(width: 220, height: 220).padding(14).background(.white, in: .rect(cornerRadius: 20))
            }
            Text(invite.code).font(.title3.monospaced().bold())
            ShareLink(item: URL(string: invite.url)!, message: Text("Join me on Asgard Chat: \(invite.url)")) {
                Label("Share invite", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }
}
