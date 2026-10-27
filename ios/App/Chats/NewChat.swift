import AsgardKit
import PhotosUI
import SwiftData
import SwiftUI

struct NewChatSheet: View {
    var onOpen: (UUID) -> Void
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var users: [User] = []
    @State private var creating: ConversationKind?
    @State private var discover: [Conversation] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = .group } label: { Label("New group", systemImage: "person.3.fill") }
                    Button { creating = .channel } label: { Label("New channel", systemImage: "megaphone.fill") }
                    Button { creating = .community } label: { Label("New community", systemImage: "building.columns.fill") }
                }
                Section("People on this server") {
                    ForEach(users) { u in
                        Button { Task { if let id = try? await engine.openDM(with: u.id) { onOpen(id) } } } label: {
                            UserRow(user: u)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !discover.isEmpty {
                    Section("Public groups and channels") {
                        ForEach(discover) { c in
                            HStack {
                                AvatarView(id: c.id, name: c.title, mediaID: c.avatarMediaID, size: 40, kind: c.kind)
                                VStack(alignment: .leading) {
                                    Text(c.title).font(.headline)
                                    Text("\(c.memberCount) members").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Join") { Task { try? await engine.join(c.id); onOpen(c.id) } }.buttonStyle(.glass)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or @username")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(200))
                users = await engine.searchUsers(query)
            }
            .task { discover = await engine.discover() }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(item: $creating) { kind in
                CreateConversationView(kind: kind, onCreated: onOpen)
            }
        }
    }
}

struct UserRow: View {
    let user: User
    var subtitle: String?
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(id: user.id, name: user.displayName, mediaID: user.avatarMediaID, size: 44, online: engine.presence[user.id]?.online ?? user.online)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName).font(.headline)
                Text(subtitle ?? "@" + user.username).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
    }
}

struct CreateConversationView: View {
    let kind: ConversationKind
    var communityID: UUID? = nil
    var onCreated: (UUID) -> Void
    @Environment(ChatEngine.self) private var engine
    @State private var title = ""
    @State private var about = ""
    @State private var query = ""
    @State private var users: [User] = []
    @State private var selected: Set<UUID> = []
    @State private var isPublic = false
    @State private var disappearing = 0
    @State private var photo: PhotosPickerItem?
    @State private var avatar: UIImage?
    @State private var working = false
    @State private var error: String?

    var noun: String { kind == .channel ? "channel" : kind == .community ? "community" : "group" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        ZStack {
                            if let avatar { Image(uiImage: avatar).resizable().scaledToFill() } else {
                                Brand.aurora
                                Image(systemName: "camera.fill").foregroundStyle(.white).font(.title2)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(kind == .community ? AnyShape(RoundedRectangle(cornerRadius: 18)) : AnyShape(Circle()))
                    }
                    VStack {
                        TextField("\(noun.capitalized) name", text: $title).font(.title3)
                        TextField("Description (optional)", text: $about, axis: .vertical).font(.subheadline)
                    }
                }
            }
            Section {
                if kind != .community { Toggle("Discoverable on this server", isOn: $isPublic) }
                if kind == .group {
                    Picker("Disappearing messages", selection: $disappearing) {
                        Text("Off").tag(0)
                        Text("24 hours").tag(86400)
                        Text("7 days").tag(7 * 86400)
                        Text("90 days").tag(90 * 86400)
                    }
                }
            } footer: {
                switch kind {
                case .channel: Text("Only admins can post in a channel. Subscribers can react, vote in polls and comment in threads.")
                case .community: Text("A community gathers groups and an announcements channel under one roof, with shared roles.")
                default: Text("Everyone in the group can send messages. Admins can change settings and manage members.")
                }
            }
            Section("Add people · \(selected.count)") {
                TextField("Search", text: $query).textInputAutocapitalization(.never)
                ForEach(users) { u in
                    Button { toggle(u.id) } label: {
                        HStack {
                            UserRow(user: u)
                            Image(systemName: selected.contains(u.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(selected.contains(u.id) ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("New \(noun)")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await create() } }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .task(id: query) { users = await engine.searchUsers(query) }
        .onChange(of: photo) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { avatar = UIImage(data: d)?.squareThumbnail(512) } }
        }
    }

    func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    func create() async {
        working = true
        defer { working = false }
        do {
            let id = try await engine.create(kind: kind, title: title, description: about, members: Array(selected),
                                             avatar: avatar?.jpegData(compressionQuality: 0.85), isPublic: isPublic, communityID: communityID,
                                             disappearingSeconds: disappearing)
            Haptics.success()
            onCreated(id)
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}

struct CommunityView: View {
    let communityID: UUID
    @Binding var path: NavigationPath
    @Environment(ChatEngine.self) private var engine
    @Query private var children: [StoredConversation]
    @State private var showCreate: ConversationKind?
    @State private var discover: [Conversation] = []

    init(communityID: UUID, path: Binding<NavigationPath>) {
        self.communityID = communityID
        _path = path
        _children = Query(filter: #Predicate<StoredConversation> { $0.communityID == communityID }, sort: \StoredConversation.title)
    }

    var community: StoredConversation? { engine.storedConversation(communityID) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(id: communityID, name: community?.title ?? "", mediaID: community?.conversation?.avatarMediaID, size: 88, kind: .community)
                    Text(community?.title ?? "").font(.title2.bold())
                    if let d = community?.conversation?.description, !d.isEmpty { Text(d).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Text("\(community?.conversation?.memberCount ?? 0) members").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section("Your chats") {
                ForEach(children) { c in
                    Button { path.append(c.id) } label: { ChatRow(conversation: c) }.buttonStyle(.plain)
                }
            }
            let joinable = discover.filter { d in d.communityID == communityID && !children.contains { $0.id == d.id } }
            if !joinable.isEmpty {
                Section("More in this community") {
                    ForEach(joinable) { c in
                        HStack {
                            AvatarView(id: c.id, name: c.title, mediaID: c.avatarMediaID, size: 40, kind: c.kind)
                            Text(c.title).font(.headline)
                            Spacer()
                            Button("Join") { Task { try? await engine.join(c.id) } }.buttonStyle(.glass)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground(intensity: 0.35))
        .navigationTitle(community?.title ?? "Community")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if community?.conversation?.me.map({ $0.permissions.contains(.editInfo) }) == true {
                Menu {
                    Button { showCreate = .group } label: { Label("New group", systemImage: "person.3") }
                    Button { showCreate = .channel } label: { Label("New channel", systemImage: "megaphone") }
                } label: { Image(systemName: "plus") }
            }
            NavigationLink(value: communityID) { Image(systemName: "info.circle") }
        }
        .sheet(item: $showCreate) { kind in
            NavigationStack {
                CreateConversationView(kind: kind, communityID: communityID) { id in
                    showCreate = nil
                    path.append(id)
                }
            }
        }
        .task { discover = await engine.discover() }
    }
}

extension ConversationKind: @retroactive Identifiable {
    public var id: String { rawValue }
}
