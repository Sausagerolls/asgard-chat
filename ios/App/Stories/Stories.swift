import AsgardKit
import PhotosUI
import SwiftData
import SwiftUI

/// A decrypted story ready to show.
struct StoryItem: Identifiable, Hashable {
    var id: UUID
    var userID: UUID
    var createdAt: Date
    var content: MessageContent
    var viewed: Bool
    var viewCount: Int
}

/// Stories use the same envelope crypto as messages. AAD binds the story to
/// its author: aad(conversation: author, senderDevice: device, clientID: author).
@MainActor
@Observable
final class StoriesModel {
    static let shared = StoriesModel()
    private(set) var byUser: [UUID: [StoryItem]] = [:]
    private(set) var loading = false

    var orderedUsers: [UUID] {
        byUser.keys.sorted { a, b in
            let ua = byUser[a]!.contains { !$0.viewed }, ub = byUser[b]!.contains { !$0.viewed }
            if ua != ub { return ua }
            return (byUser[a]!.last?.createdAt ?? .distantPast) > (byUser[b]!.last?.createdAt ?? .distantPast)
        }
    }

    func load(_ engine: ChatEngine) async {
        if engine.isDemo { loadDemo(); return }
        guard let api = engine.api, let account = engine.account, let keys = try? account.deviceKeys() else { return }
        loading = true
        defer { loading = false }
        guard let stories: [Story] = try? await api.send("GET", "/stories") else { return }
        var out: [UUID: [StoryItem]] = [:]
        for s in stories {
            if SigningKeyCache.get(s.senderDeviceID) == nil, let d = try? await api.devices(of: s.userID) { SigningKeyCache.put(d) }
            guard let wk = s.wrappedKey,
                  let key = try? E2EE.unwrap(wk, identity: keys.identity, clientID: s.userID) else { continue }
            let aad = E2EE.aad(conversation: s.userID, senderDevice: s.senderDeviceID, clientID: s.userID)
            guard let pt = try? E2EE.open(s.ciphertext, key: key, aad: aad), let c = try? JSONDecoder().decode(MessageContent.self, from: pt) else { continue }
            if let sk = SigningKeyCache.get(s.senderDeviceID), !E2EE.verify(sk, aad: aad, ciphertext: s.ciphertext, signature: s.signature) { continue }
            out[s.userID, default: []].append(StoryItem(id: s.id, userID: s.userID, createdAt: s.createdAt, content: c, viewed: s.viewed || s.userID == engine.myID, viewCount: s.viewCount))
        }
        byUser = out
    }

    func post(_ content: MessageContent, audience: [UUID], engine: ChatEngine) async throws {
        if engine.isDemo, let me = engine.myID {
            byUser[me, default: []].append(StoryItem(id: UUID(), userID: me, createdAt: .now, content: content, viewed: true, viewCount: 0))
            return
        }
        guard let api = engine.api, let account = engine.account, let keys = try? account.deviceKeys() else { throw APIError.offline }
        let me = account.userID
        let aad = E2EE.aad(conversation: me, senderDevice: account.deviceID, clientID: me)
        let sealed = try E2EE.seal(try JSONEncoder().encode(content), aad: aad)
        var wrapped: [String: Data] = [:]
        for user in Set(audience + [me]) {
            for d in (try? await api.devices(of: user)) ?? [] {
                wrapped[d.id.lower] = try E2EE.wrap(sealed.key, for: d.identityKey, clientID: me)
            }
        }
        nonisolated struct Body: Encodable, Sendable { var ciphertext: Data; var signature: Data; var keys: [String: Data] }
        try await api.call("POST", "/stories", body: Body(ciphertext: sealed.ciphertext, signature: try E2EE.sign(keys.signing, aad: aad, ciphertext: sealed.ciphertext), keys: wrapped))
        await load(engine)
    }

    func markViewed(_ story: StoryItem, reaction: String = "", engine: ChatEngine) {
        if var list = byUser[story.userID], let i = list.firstIndex(where: { $0.id == story.id }) {
            list[i].viewed = true
            byUser[story.userID] = list
        }
        guard !engine.isDemo, story.userID != engine.myID else { return }
        nonisolated struct Body: Encodable, Sendable { var reaction: String }
        Task { try? await engine.api?.call("POST", "/stories/\(story.id.lower)/view", body: Body(reaction: reaction)) }
    }

    func delete(_ story: StoryItem, engine: ChatEngine) async {
        byUser[story.userID]?.removeAll { $0.id == story.id }
        if byUser[story.userID]?.isEmpty == true { byUser[story.userID] = nil }
        try? await engine.api?.call("DELETE", "/stories/\(story.id.lower)")
    }

    private func loadDemo() {
        guard byUser.isEmpty else { return }
        func text(_ t: String, _ bg: String) -> MessageContent { var c = MessageContent.text(t); c.emoji = bg; return c }
        let u = DemoData.users
        byUser = [
            u[1].id: [StoryItem(id: UUID(), userID: u[1].id, createdAt: .now.addingTimeInterval(-3600), content: text("Falcon cloak fitting today 🪶", "aurora"), viewed: false, viewCount: 0),
                      StoryItem(id: UUID(), userID: u[1].id, createdAt: .now.addingTimeInterval(-1800), content: text("Cats pulled the chariot again 🐈🐈", "dusk"), viewed: false, viewCount: 0)],
            u[0].id: [StoryItem(id: UUID(), userID: u[0].id, createdAt: .now.addingTimeInterval(-7000), content: text("New hammer who dis ⚡️🔨", "fjord"), viewed: false, viewCount: 0)],
            u[3].id: [StoryItem(id: UUID(), userID: u[3].id, createdAt: .now.addingTimeInterval(-20000), content: text("Bifröst sunrise. Nobody crossed. Good.", "gold"), viewed: true, viewCount: 0)],
        ]
    }
}

enum StoryBackground: String, CaseIterable {
    case aurora, dusk, fjord, gold, night
    var gradient: LinearGradient {
        switch self {
        case .aurora: Brand.aurora
        case .dusk: LinearGradient(colors: [Color(red: 0.3, green: 0.1, blue: 0.4), Color(red: 0.95, green: 0.45, blue: 0.35)], startPoint: .top, endPoint: .bottom)
        case .fjord: LinearGradient(colors: [Color(red: 0.05, green: 0.2, blue: 0.35), Brand.teal], startPoint: .top, endPoint: .bottom)
        case .gold: LinearGradient(colors: [Brand.gold, Color(red: 0.9, green: 0.4, blue: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .night: LinearGradient(colors: [Brand.night, Brand.navy], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct StoriesStrip: View {
    @Environment(ChatEngine.self) private var engine
    private var model: StoriesModel { .shared }
    @State private var viewing: UUID?
    @State private var composing = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button {
                    if let me = engine.myID, model.byUser[me] != nil { viewing = me } else { composing = true }
                } label: {
                    VStack(spacing: 4) {
                        AvatarView(id: engine.myID, name: engine.me?.displayName ?? "Me", mediaID: engine.me?.avatarMediaID, size: 58,
                                   storyRing: model.byUser[engine.myID ?? UUID()] != nil ? .seen : .none)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus.circle.fill").font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                                    .onTapGesture { composing = true }
                            }
                        Text("My story").font(.caption2).lineLimit(1)
                    }
                    .frame(width: 70)
                }
                .buttonStyle(.plain)
                ForEach(model.orderedUsers.filter { $0 != engine.myID }, id: \.self) { uid in
                    let u = engine.user(uid)
                    Button { viewing = uid } label: {
                        VStack(spacing: 4) {
                            AvatarView(id: uid, name: u?.displayName ?? "", mediaID: u?.avatarMediaID, size: 58,
                                       storyRing: model.byUser[uid]?.contains { !$0.viewed } == true ? .unseen : .seen)
                            Text(u?.displayName ?? "").font(.caption2).lineLimit(1)
                        }
                        .frame(width: 70)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .task(id: engine.storyRevision) { await model.load(engine) }
        .fullScreenCover(item: Binding(get: { viewing.map(IdentifiedUUID.init) }, set: { viewing = $0?.id })) { v in
            StoryViewer(startUser: v.id)
        }
        .sheet(isPresented: $composing) { StoryComposer() }
    }
}

struct IdentifiedUUID: Identifiable { var id: UUID }

struct StoriesTab: View {
    @Environment(ChatEngine.self) private var engine
    private var model: StoriesModel { .shared }
    @State private var viewing: UUID?
    @State private var composing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { composing = true } label: {
                        HStack(spacing: 14) {
                            AvatarView(id: engine.myID, name: engine.me?.displayName ?? "Me", mediaID: engine.me?.avatarMediaID, size: 52)
                            VStack(alignment: .leading) {
                                Text("My story").font(.headline)
                                Text(model.byUser[engine.myID ?? UUID()].map { "\($0.count) update\($0.count == 1 ? "" : "s") · \($0.reduce(0) { $0 + $1.viewCount }) views" } ?? "Tap to add an update")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "camera.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
                let others = model.orderedUsers.filter { $0 != engine.myID }
                let unseen = others.filter { model.byUser[$0]?.contains { !$0.viewed } == true }
                let seen = others.filter { !unseen.contains($0) }
                if !unseen.isEmpty { Section("Recent") { ForEach(unseen, id: \.self) { row($0, ring: .unseen) } } }
                if !seen.isEmpty { Section("Viewed") { ForEach(seen, id: \.self) { row($0, ring: .seen) } } }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackground(intensity: 0.35))
            .overlay { if model.byUser.isEmpty && !model.loading { ContentUnavailableView("No stories", systemImage: "circle.dashed", description: Text("Updates from people you chat with appear here for 24 hours.")) } }
            .navigationTitle("Stories")
            .refreshable { await model.load(engine) }
            .task(id: engine.storyRevision) { await model.load(engine) }
            .fullScreenCover(item: Binding(get: { viewing.map(IdentifiedUUID.init) }, set: { viewing = $0?.id })) { StoryViewer(startUser: $0.id) }
            .sheet(isPresented: $composing) { StoryComposer() }
        }
    }

    func row(_ uid: UUID, ring: AvatarView.StoryRing) -> some View {
        let u = engine.user(uid)
        return Button { viewing = uid } label: {
            HStack(spacing: 14) {
                AvatarView(id: uid, name: u?.displayName ?? "", mediaID: u?.avatarMediaID, size: 52, storyRing: ring)
                VStack(alignment: .leading) {
                    Text(u?.displayName ?? "").font(.headline)
                    Text(model.byUser[uid]?.last?.createdAt.formatted(.relative(presentation: .named)) ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct StoryViewer: View {
    let startUser: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    private var model: StoriesModel { .shared }
    @State private var userIndex = 0
    @State private var index = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var reply = ""
    @State private var showViews = false
    @FocusState private var replying: Bool

    var users: [UUID] { model.orderedUsers }
    var stories: [StoryItem] { users.indices.contains(userIndex) ? model.byUser[users[userIndex]] ?? [] : [] }
    var story: StoryItem? { stories.indices.contains(index) ? stories[index] : nil }
    let duration: Double = 6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let story { StoryContentView(story: story).ignoresSafeArea(edges: .bottom) }
            HStack(spacing: 0) {
                Color.clear.contentShape(.rect).onTapGesture { step(-1) }
                Color.clear.contentShape(.rect).onTapGesture { step(1) }
            }
            .onLongPressGesture(minimumDuration: 0.2, pressing: { paused = $0 }, perform: {})
            VStack {
                HStack(spacing: 4) {
                    ForEach(stories.indices, id: \.self) { i in
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.35))
                                .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * (i < index ? 1 : i == index ? progress : 0)) }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal).padding(.top, 8)
                HStack {
                    if let story {
                        let u = engine.user(story.userID)
                        AvatarView(id: story.userID, name: u?.displayName ?? "", mediaID: u?.avatarMediaID, size: 36)
                        VStack(alignment: .leading) {
                            Text(story.userID == engine.myID ? "My story" : u?.displayName ?? "").font(.subheadline.bold())
                            Text(story.createdAt.formatted(.relative(presentation: .named))).font(.caption)
                        }
                        .foregroundStyle(.white)
                    }
                    Spacer()
                    if story?.userID == engine.myID {
                        Menu {
                            Button(role: .destructive) { if let story { Task { await model.delete(story, engine: engine); dismiss() } } } label: { Label("Delete", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis").foregroundStyle(.white).frame(width: 36, height: 36) }
                    }
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white).frame(width: 36, height: 36) }
                }
                .padding(.horizontal)
                Spacer()
                if story?.userID == engine.myID {
                    Button { showViews = true } label: { Label("\(story?.viewCount ?? 0) views", systemImage: "eye").foregroundStyle(.white) }
                        .padding(.bottom, 24)
                } else {
                    HStack {
                        TextField("Reply…", text: $reply).focused($replying).padding(12).glassEffect(.regular.interactive(), in: .capsule)
                            .onSubmit { sendReply() }
                        ForEach(["❤️", "😂", "🔥"], id: \.self) { e in
                            Button(e) { if let story { model.markViewed(story, reaction: e, engine: engine); Haptics.tap() } }.font(.title2)
                        }
                    }
                    .padding()
                }
            }
        }
        .gesture(DragGesture().onEnded { if $0.translation.height > 100 { dismiss() } })
        .onAppear { userIndex = max(0, users.firstIndex(of: startUser) ?? 0) }
        .task(id: "\(userIndex)-\(index)") { await run() }
        .onChange(of: replying) { _, r in paused = r }
        .sheet(isPresented: $showViews) {
            if let story { StoryViewsSheet(storyID: story.id) }
        }
        .statusBarHidden()
    }

    func run() async {
        progress = 0
        if let story { model.markViewed(story, engine: engine) }
        while progress < 1 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            if !paused && !showViews { progress += 0.05 / duration }
        }
        step(1)
    }

    func step(_ d: Int) {
        let next = index + d
        if next >= 0 && next < stories.count { index = next; return }
        let nu = userIndex + d
        if nu >= 0 && nu < users.count { userIndex = nu; index = d > 0 ? 0 : max(0, (model.byUser[users[nu]]?.count ?? 1) - 1) }
        else if d > 0 { dismiss() }
    }

    func sendReply() {
        guard let story, !reply.isEmpty else { return }
        let text = reply
        reply = ""
        replying = false
        Task {
            if let conv = try? await engine.openDM(with: story.userID) {
                await engine.send(.text("↩︎ Replying to your story: \(text)"), to: conv)
                engine.banner = "Reply sent"
            }
        }
    }
}

struct StoryContentView: View {
    let story: StoryItem
    @Environment(ChatEngine.self) private var engine
    @State private var image: UIImage?

    var body: some View {
        if let a = story.content.attachments?.first {
            ZStack {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView().tint(.white) }
                if let t = story.content.text, !t.isEmpty {
                    Text(t).font(.title3.weight(.semibold)).foregroundStyle(.white).padding().background(.black.opacity(0.4), in: .rect(cornerRadius: 12))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
                }
            }
            .task { if let d = try? await engine.attachmentData(a) { image = UIImage(data: d) } }
        } else {
            ZStack {
                (StoryBackground(rawValue: story.content.emoji ?? "") ?? .aurora).gradient
                Text(story.content.text ?? "").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(32)
            }
        }
    }
}

struct StoryViewsSheet: View {
    let storyID: UUID
    @Environment(ChatEngine.self) private var engine
    @State private var views: [ViewRow] = []
    nonisolated struct ViewRow: Codable, Identifiable, Sendable { var viewer_id: UUID; var viewed_at: Date; var reaction: String; var id: UUID { viewer_id } }

    var body: some View {
        NavigationStack {
            List(views) { v in
                HStack {
                    if let u = engine.user(v.viewer_id) { UserRow(user: u, subtitle: v.viewed_at.formatted(.relative(presentation: .named))) }
                    Spacer()
                    Text(v.reaction).font(.title2)
                }
            }
            .overlay { if views.isEmpty { ContentUnavailableView("No views yet", systemImage: "eye.slash") } }
            .navigationTitle("Viewed by")
            .task { views = (try? await engine.api?.send("GET", "/stories/\(storyID.lower)/views")) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }
}

struct StoryComposer: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var bg: StoryBackground = .aurora
    @State private var photo: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var audience: Audience = .everyone
    @State private var closeFriends: Set<UUID> = []
    @State private var posting = false
    @State private var peers: [User] = []

    enum Audience: String, CaseIterable { case everyone = "Everyone I chat with", closeFriends = "Close friends" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if let image { Image(uiImage: image).resizable().scaledToFill() } else { bg.gradient }
                    TextField("Type something…", text: $text, axis: .vertical)
                        .font(.system(size: 30, weight: .bold, design: .rounded)).multilineTextAlignment(.center).foregroundStyle(.white).padding(28)
                }
                .frame(maxWidth: .infinity).aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 24))
                HStack {
                    ForEach(StoryBackground.allCases, id: \.self) { b in
                        Circle().fill(b.gradient).frame(width: 32, height: 32).overlay(Circle().stroke(.white, lineWidth: bg == b ? 3 : 0))
                            .onTapGesture { bg = b; image = nil }
                    }
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo").font(.title2) }
                }
                Picker("Audience", selection: $audience) { ForEach(Audience.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if audience == .closeFriends {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(peers) { u in
                                Button { if closeFriends.contains(u.id) { closeFriends.remove(u.id) } else { closeFriends.insert(u.id) } } label: {
                                    VStack {
                                        AvatarView(id: u.id, name: u.displayName, mediaID: u.avatarMediaID, size: 44, storyRing: closeFriends.contains(u.id) ? .unseen : .none)
                                        Text(u.displayName).font(.caption2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("New story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") { Task { await post() } }.disabled(posting || (text.isEmpty && image == nil))
                }
            }
            .onChange(of: photo) { _, item in Task { if let d = try? await item?.loadTransferable(type: Data.self) { image = UIImage(data: d) } } }
            .task { peers = await engine.searchUsers("") }
        }
    }

    func post() async {
        posting = true
        defer { posting = false }
        var content: MessageContent
        if let image, let file = MediaPrep.image(image.jpegData(compressionQuality: 0.9) ?? Data()), let api = engine.api {
            do {
                let enc = try MediaCrypto.encrypt(file.data)
                let id = try await api.upload(enc.blob, ttl: 86400)
                MediaCache.store(file.data, for: id)
                content = MessageContent(type: .media, text: text.isEmpty ? nil : text)
                content.attachments = [.init(mediaID: id, mime: file.mime, size: file.data.count, key: enc.key, digest: enc.digest, width: file.width, height: file.height, thumbnail: file.thumbnail)]
            } catch { engine.banner = "Couldn't upload photo."; return }
        } else {
            content = .text(text)
            content.emoji = bg.rawValue
        }
        let everyone = Set(((try? engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []).compactMap { $0.conversation?.peer?.id })
        let audienceIDs = audience == .closeFriends ? Array(closeFriends) : Array(everyone)
        do {
            try await StoriesModel.shared.post(content, audience: audienceIDs, engine: engine)
            Haptics.success()
            dismiss()
        } catch {
            engine.banner = (error as? APIError)?.message ?? "Couldn't post story."
        }
    }
}
