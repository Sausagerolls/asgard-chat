import Foundation
import Observation
import SwiftData

/// The app's single source of truth: account, sync, encryption and sending.
/// Views read conversations and messages through SwiftData queries on
/// `container`, and call the methods here to act.
@MainActor
@Observable
public final class ChatEngine {
    public enum Phase: Equatable { case loading, signedOut, ready }

    public struct IncomingCall: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var conversationID: UUID
        public var callerID: UUID
        public var callerName: String
        public var video: Bool
        public init(id: UUID, conversationID: UUID, callerID: UUID, callerName: String, video: Bool) {
            self.id = id; self.conversationID = conversationID; self.callerID = callerID; self.callerName = callerName; self.video = video
        }
    }

    public struct TypingState: Equatable, Sendable {
        public var state: String
        public var at: Date
    }

    public private(set) var phase: Phase = .loading
    public internal(set) var me: User?
    public private(set) var serverInfo: ServerInfo?
    /// False when the server runs without LiveKit, so the apps hide call buttons.
    public var callsAvailable: Bool { isDemo || serverInfo?.features.calls != false }
    public private(set) var connection: ConnectionState = .disconnected
    public internal(set) var typing: [UUID: [UUID: TypingState]] = [:]
    public internal(set) var readMarks: [UUID: [UUID: Int64]] = [:]
    public private(set) var deliveredMarks: [UUID: [UUID: Int64]] = [:]
    public private(set) var presence: [UUID: (online: Bool, lastSeen: Date?)] = [:]
    public var incomingCall: IncomingCall?
    /// Who is in each conversation's voice room (only occupied rooms are listed).
    public internal(set) var voiceRooms: [UUID: [VoiceParticipant]] = [:]
    /// The conversation whose voice room this device is in.
    public var currentVoiceRoom: UUID?
    /// Message history sync and recovery (see HistorySync.swift).
    public internal(set) var history = HistoryState()
    public var activeConversation: UUID?
    public var banner: String?
    public private(set) var isDemo: Bool

    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public private(set) var api: APIClient?
    public private(set) var account: Keychain.Account?

    var keys: DeviceKeys?
    var realtime: RealtimeClient?
    var deviceCache: [UUID: [DeviceInfo]] = [:]
    var userFetches: Set<UUID> = []
    var lastTypingSent: [UUID: Date] = [:]
    var syncing = false
    var tasks: [Task<Void, Never>] = []

    public var onIncomingCall: ((IncomingCall) -> Void)?
    public var onCallEnded: ((UUID) -> Void)?
    public var onDeviceLinked: ((String) -> Void)?
    /// A new message from someone else arrived over the live connection
    /// (desktop apps raise their own notifications from this).
    public var onIncomingMessage: ((StoredMessage) -> Void)?

    var cursorKey: String { "syncCursor-" + (account?.deviceID.lower ?? "none") }
    var cursor: Int64 {
        get { Int64(AppGroup.defaults.integer(forKey: cursorKey)) }
        set { AppGroup.defaults.set(Int(newValue), forKey: cursorKey) }
    }

    /// Where the session and device keys live. Tests swap in memory storage.
    public var accountStore: AccountStore = .keychain

    public init(container: ModelContainer, demo: Bool = false) {
        self.container = container
        self.isDemo = demo || AppGroup.defaults.bool(forKey: "demoMode")
    }

    // MARK: - Lifecycle

    public func start() async {
        if isDemo {
            DemoData.seed(self)
            phase = .ready
            return
        }
        guard let account = accountStore.load(), let keys = try? account.deviceKeys() else {
            phase = .signedOut
            return
        }
        await activate(account: account, keys: keys, user: nil)
    }

    func activate(account: Keychain.Account, keys: DeviceKeys, user: User?) async {
        self.account = account
        self.keys = keys
        api = APIClient(baseURL: account.serverURL, token: account.token)
        me = user ?? cachedUser(account.userID)
        phase = .ready
        connectRealtime()
        tasks.append(Task {
            await self.refreshAll()
            await self.repairRecentHistory()
            await self.refreshHistoryStatus()
            if self.history.hasKey { await self.importHistory(); await self.backfillHistory() }
        })
        tasks.append(Task { await self.refreshVoiceRooms() })
        tasks.append(Task { await self.expiryLoop() })
    }

    public func refreshAll() async {
        guard let api, !isDemo else { return }
        do {
            async let info = api.info()
            async let meUser: User = api.send("GET", "/me")
            serverInfo = try await info
            let u = try await meUser
            me = u
            store(u)
        } catch let e as APIError where e.status == 401 {
            await signOutLocally()
            return
        } catch {}
        await refreshConversations()
        await syncNow()
    }

    public func foreground() {
        realtime?.reconnectNow()
        Task { await syncNow() }
    }

    func connectRealtime() {
        guard let api, let token = api.token else { return }
        realtime?.stop()
        let rt = RealtimeClient(url: api.webSocketURL, token: token)
        realtime = rt
        tasks.append(Task { [weak self] in
            for await ev in rt.events { self?.handle(ev) }
        })
        tasks.append(Task { [weak self] in
            for await s in rt.states {
                guard let self else { return }
                let wasOffline = self.connection != .connected
                self.connection = s
                if s == .connected && wasOffline { Task { await self.syncNow(); await self.refreshVoiceRooms() } }
            }
        })
        rt.start()
    }

    // MARK: - Account

    public static func newDeviceName() -> String {
        #if os(iOS)
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #else
        return Host.current().localizedName ?? "Device"
        #endif
    }

    static var platform: String {
        #if os(watchOS)
        "watchos"
        #elseif os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    public func signUp(server: URL, invite: String, username: String, displayName: String, password: String, deviceName: String) async throws {
        let keys = DeviceKeys()
        let session = try await APIClient(baseURL: server, token: nil)
            .register(invite: invite, username: username, password: password, displayName: displayName,
                      device: .init(name: deviceName, platform: Self.platform, keys: keys))
        try await finishSignIn(server: server, session: session, keys: keys)
    }

    public func signIn(server: URL, username: String, password: String, deviceName: String) async throws {
        let keys = DeviceKeys()
        let session = try await APIClient(baseURL: server, token: nil)
            .login(username: username, password: password, device: .init(name: deviceName, platform: Self.platform, keys: keys))
        try await finishSignIn(server: server, session: session, keys: keys)
    }

    public func claimDeviceLink(server: URL, code: String, deviceName: String) async throws {
        let keys = DeviceKeys()
        let session = try await APIClient(baseURL: server, token: nil)
            .claimLink(code: code, device: .init(name: deviceName, platform: Self.platform, keys: keys))
        try await finishSignIn(server: server, session: session, keys: keys)
    }

    func finishSignIn(server: URL, session: Session, keys: DeviceKeys) async throws {
        let account = Keychain.Account(serverURL: server, token: session.token, userID: session.user.id, deviceID: session.deviceID,
                                       identityPrivate: keys.identity.rawRepresentation, signingPrivate: keys.signing.rawRepresentation)
        try accountStore.save(account)
        self.account = account
        cursor = 0
        store(session.user)
        await activate(account: account, keys: keys, user: session.user)
    }

    public func enterDemo() {
        AppGroup.defaults.set(true, forKey: "demoMode")
        isDemo = true
        DemoData.seed(self)
        phase = .ready
    }

    public func signOut() async {
        if !isDemo, let api { try? await api.call("POST", "/auth/logout") }
        await signOutLocally()
    }

    func signOutLocally() async {
        realtime?.stop()
        realtime = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        cursor = 0
        accountStore.delete()
        AppGroup.defaults.removeObject(forKey: "demoMode")
        try? context.delete(model: StoredMessage.self)
        try? context.delete(model: StoredConversation.self)
        try? context.delete(model: StoredUser.self)
        try? context.delete(model: PendingOp.self)
        try? context.delete(model: StoredCall.self)
        try? context.save()
        MediaCache.clear()
        api = nil
        account = nil
        keys = nil
        me = nil
        isDemo = false
        deviceCache = [:]
        phase = .signedOut
    }

    public var myID: UUID? { me?.id ?? account?.userID }
    public var myDeviceID: UUID? { account?.deviceID }

    // MARK: - Users

    public func user(_ id: UUID?) -> User? {
        guard let id else { return nil }
        if id == me?.id { return me }
        if let u = cachedUser(id) { return u }
        fetchUser(id)
        return nil
    }

    public func name(_ id: UUID?) -> String {
        guard let id else { return "Someone" }
        if id == myID { return "You" }
        return user(id)?.displayName ?? "…"
    }

    func cachedUser(_ id: UUID) -> User? {
        var d = FetchDescriptor<StoredUser>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.user
    }

    func fetchUser(_ id: UUID) {
        guard let api, !userFetches.contains(id) else { return }
        userFetches.insert(id)
        Task {
            if let u: User = try? await api.send("GET", "/users/\(id.lower)") { store(u) }
            userFetches.remove(id)
        }
    }

    public func store(_ u: User) {
        let id = u.id
        var d = FetchDescriptor<StoredUser>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let existing = (try? context.fetch(d))?.first { existing.update(u) } else { context.insert(StoredUser(u)) }
        if u.id == me?.id { me = u }
        presence[u.id] = (u.online, u.lastSeenAt)
        try? context.save()
    }

    public func searchUsers(_ q: String) async -> [User] {
        if isDemo { return DemoData.users.filter { q.isEmpty || $0.displayName.localizedCaseInsensitiveContains(q) || $0.username.contains(q.lowercased()) } }
        guard let api else { return [] }
        let users: [User] = (try? await api.send("GET", "/users", query: [.init(name: "q", value: q)])) ?? []
        users.forEach(store)
        return users.filter { $0.id != myID }
    }

    public func updateProfile(displayName: String? = nil, bio: String? = nil, avatar: Data? = nil, settings: [String: JSONValue]? = nil) async throws {
        guard let api else {
            if var m = me { if let displayName { m.displayName = displayName }; if let bio { m.bio = bio }; me = m }
            return
        }
        var avatarID: UUID?
        if let avatar { avatarID = try await api.upload(avatar, purpose: "avatar", contentType: "image/jpeg") }
        struct Body: Encodable, Sendable {
            var display_name: String?; var bio: String?; var avatar_media_id: UUID?; var settings: [String: JSONValue]?
        }
        let u: User = try await api.send("PATCH", "/me", body: Body(display_name: displayName, bio: bio, avatar_media_id: avatarID, settings: settings))
        store(u)
    }

    // MARK: - Conversations

    public func storedConversation(_ id: UUID) -> StoredConversation? {
        var d = FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    public func conversation(_ id: UUID) -> Conversation? { storedConversation(id)?.conversation }

    public func refreshConversations() async {
        guard let api else { return }
        guard let list = try? await api.conversations() else { return }
        let ids = Set(list.map(\.id))
        for c in list { upsert(c) }
        for stale in (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? [] where !ids.contains(stale.id) {
            context.delete(stale)
        }
        try? context.save()
    }

    @discardableResult
    func upsert(_ c: Conversation) -> StoredConversation {
        if let p = c.peer { store(p) }
        let sc: StoredConversation
        if let existing = storedConversation(c.id) {
            existing.update(from: c)
            sc = existing
        } else {
            sc = StoredConversation(c)
            context.insert(sc)
        }
        if let last = c.lastMessage, sc.previewDate == nil || sc.previewDate! < last.sentAt {
            process(last, live: false)
        }
        if c.id == activeConversation { sc.unread = 0 }
        return sc
    }

    public func refreshConversation(_ id: UUID) async {
        guard let api, let c = try? await api.conversation(id) else { return }
        upsert(c)
        try? context.save()
    }

    public func openDM(with user: UUID) async throws -> UUID {
        if isDemo { return DemoData.dm(with: user, engine: self) }
        guard let api else { throw APIError.offline }
        struct Body: Encodable, Sendable { var kind = "dm"; var member_ids: [UUID] }
        let c: Conversation = try await api.send("POST", "/conversations", body: Body(member_ids: [user]))
        upsert(c)
        try? context.save()
        return c.id
    }

    public func create(kind: ConversationKind, title: String, description: String = "", members: [UUID], avatar: Data? = nil,
                       isPublic: Bool = false, communityID: UUID? = nil, disappearingSeconds: Int = 0) async throws -> UUID {
        if isDemo { return DemoData.create(kind: kind, title: title, members: members, engine: self) }
        guard let api else { throw APIError.offline }
        var avatarID: UUID?
        if let avatar { avatarID = try await api.upload(avatar, purpose: "avatar", contentType: "image/jpeg") }
        struct Body: Encodable, Sendable {
            var kind: String; var title: String; var description: String; var member_ids: [UUID]; var avatar_media_id: UUID?
            var is_public: Bool; var community_id: UUID?; var disappearing_seconds: Int
        }
        let c: Conversation = try await api.send("POST", "/conversations", body: Body(
            kind: kind.rawValue, title: title, description: description, member_ids: members, avatar_media_id: avatarID,
            is_public: isPublic, community_id: communityID, disappearing_seconds: disappearingSeconds))
        upsert(c)
        if kind == .community { await refreshConversations() }
        try? context.save()
        return c.id
    }

    public struct ConversationPatch: Encodable, Sendable {
        public var title: String?
        public var description: String?
        public var avatar_media_id: UUID?
        public var disappearing_seconds: Int?
        public var slow_mode_seconds: Int?
        public var member_permissions: Int64?
        public var is_public: Bool?
        public init(title: String? = nil, description: String? = nil, disappearingSeconds: Int? = nil, slowModeSeconds: Int? = nil,
                    memberPermissions: Int64? = nil, isPublic: Bool? = nil) {
            self.title = title; self.description = description; disappearing_seconds = disappearingSeconds
            slow_mode_seconds = slowModeSeconds; member_permissions = memberPermissions; is_public = isPublic
        }
    }

    public func update(_ id: UUID, _ patch: ConversationPatch, avatar: Data? = nil) async throws {
        guard let api else {
            if let sc = storedConversation(id), var c = sc.conversation {
                if let t = patch.title { c.title = t }
                if let d = patch.disappearing_seconds { c.disappearingSeconds = d }
                sc.update(from: c)
            }
            return
        }
        var patch = patch
        if let avatar { patch.avatar_media_id = try await api.upload(avatar, purpose: "avatar", contentType: "image/jpeg") }
        let c: Conversation = try await api.send("PATCH", "/conversations/\(id.lower)", body: patch)
        upsert(c)
        try? context.save()
    }

    public struct Prefs: Encodable, Sendable {
        public var muted_until: Date?
        public var unmute: Bool?
        public var pinned: Bool?
        public var archived: Bool?
        public var folder: String?
        public init(mutedUntil: Date? = nil, unmute: Bool? = nil, pinned: Bool? = nil, archived: Bool? = nil, folder: String? = nil) {
            muted_until = mutedUntil; self.unmute = unmute; self.pinned = pinned; self.archived = archived; self.folder = folder
        }
    }

    public func setPrefs(_ id: UUID, _ prefs: Prefs) async {
        if let sc = storedConversation(id) {
            if let p = prefs.pinned { sc.pinned = p }
            if let a = prefs.archived { sc.archived = a }
            if let f = prefs.folder { sc.folder = f }
            if prefs.unmute == true { sc.mutedUntil = nil } else if let m = prefs.muted_until { sc.mutedUntil = m }
            try? context.save()
        }
        guard let api else { return }
        if let c: Conversation = try? await api.send("PUT", "/conversations/\(id.lower)/prefs", body: prefs) {
            upsert(c)
            try? context.save()
        }
    }

    public func members(_ id: UUID) async -> [Member] {
        if isDemo { return DemoData.members(id, engine: self) }
        guard let api, let members = try? await api.members(of: id) else { return [] }
        for m in members {
            store(m.user)
            readMarks[id, default: [:]][m.user.id] = max(readMarks[id]?[m.user.id] ?? 0, m.readSeq)
        }
        return members
    }

    public func addMembers(_ ids: [UUID], to conv: UUID) async throws {
        struct Body: Encodable, Sendable { var user_ids: [UUID] }
        try await api?.call("POST", "/conversations/\(conv.lower)/members", body: Body(user_ids: ids))
        deviceCache[conv] = nil
    }

    public func setRole(_ role: MemberRole, for user: UUID, in conv: UUID) async throws {
        struct Body: Encodable, Sendable { var role: String }
        try await api?.call("PATCH", "/conversations/\(conv.lower)/members/\(user.lower)", body: Body(role: role.rawValue))
    }

    public func removeMember(_ user: UUID, from conv: UUID) async throws {
        try await api?.call("DELETE", "/conversations/\(conv.lower)/members/\(user.lower)")
        deviceCache[conv] = nil
    }

    public func leave(_ conv: UUID) async throws {
        try await api?.call("POST", "/conversations/\(conv.lower)/leave")
        removeLocal(conv)
    }

    public func deleteConversation(_ conv: UUID) async throws {
        try await api?.call("DELETE", "/conversations/\(conv.lower)")
        removeLocal(conv)
    }

    public func join(_ conv: UUID) async throws {
        guard let api else { return }
        let c: Conversation = try await api.send("POST", "/conversations/\(conv.lower)/join")
        upsert(c)
        try? context.save()
        await loadOlder(conv)
    }

    public func discover() async -> [Conversation] {
        guard let api else { return [] }
        return (try? await api.send("GET", "/conversations/discover")) ?? []
    }

    /// Removes messages from this device only.
    public func clearHistory(_ conv: UUID) {
        try? context.delete(model: StoredMessage.self, where: #Predicate { $0.conversationID == conv })
        storedConversation(conv)?.previewText = ""
        try? context.save()
    }

    func removeLocal(_ conv: UUID) {
        try? context.delete(model: StoredMessage.self, where: #Predicate { $0.conversationID == conv })
        if let sc = storedConversation(conv) { context.delete(sc) }
        try? context.save()
    }

    // MARK: - Messages: receiving

    public func syncNow() async {
        guard let api, !syncing, !isDemo else { return }
        syncing = true
        defer { syncing = false }
        var more = true
        while more {
            guard let page = try? await api.sync(after: cursor) else { return }
            await prefetchSigningKeys(page.envelopes)
            for env in page.envelopes { process(env, live: false) }
            cursor = max(cursor, page.nextCursor)
            more = page.more
            try? context.save()
        }
    }

    public func loadOlder(_ conv: UUID) async {
        guard let api, !isDemo else { return }
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conv && $0.seq > 0 }, sortBy: [SortDescriptor(\.seq)])
        d.fetchLimit = 1
        let oldest = (try? context.fetch(d))?.first?.seq
        guard let envs = try? await api.history(conv, before: oldest) else { return }
        await prefetchSigningKeys(envs)
        // History arrives newest first; apply oldest first so edits find targets.
        for env in envs.reversed() { process(env, live: false, countUnread: false) }
        try? context.save()
    }

    /// Re-reads recent history for every chat. Used once after a build that
    /// dropped incoming messages: anything already stored is left as is.
    public func repairRecentHistory() async {
        guard let api, !isDemo, let device = myDeviceID else { return }
        let flag = "historyRepair-v1-" + device.lower
        guard !AppGroup.defaults.bool(forKey: flag) else { return }
        let convs = (try? context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        for c in convs where c.kind != .community {
            guard let envs = try? await api.history(c.id, before: nil, limit: 100) else { continue }
            await prefetchSigningKeys(envs)
            for env in envs.reversed() { process(env, live: false, countUnread: true) }
        }
        try? context.save()
        AppGroup.defaults.set(true, forKey: flag)
    }

    func prefetchSigningKeys(_ envs: [Envelope]) async {
        guard let api else { return }
        let missing = Set(envs.compactMap { e -> UUID? in
            guard let d = e.senderDeviceID, SigningKeyCache.get(d) == nil else { return nil }
            return e.senderUserID
        })
        for user in missing {
            if let devices = try? await api.devices(of: user) { SigningKeyCache.put(devices) }
        }
    }

    func handle(_ ev: RealtimeEvent) {
        switch ev.type {
        case "message":
            guard let env = ev.decode(Envelope.self) else { return }
            if let d = env.senderDeviceID, SigningKeyCache.get(d) == nil {
                Task {
                    await prefetchSigningKeys([env])
                    process(env, live: true)
                    try? context.save()
                }
            } else {
                process(env, live: true)
                try? context.save()
            }
            if let c = env.cursor { cursor = max(cursor, c) }
            if env.senderUserID != myID {
                realtime?.send(type: "ack", data: AckFrame(conversation_id: env.conversationID, seq: env.seq))
            }
        case "receipt":
            struct R: Decodable { var conversation_id: UUID; var user_id: UUID; var read_seq: Int64?; var delivered_seq: Int64? }
            guard let r = ev.decode(R.self) else { return }
            if let s = r.read_seq {
                readMarks[r.conversation_id, default: [:]][r.user_id] = max(readMarks[r.conversation_id]?[r.user_id] ?? 0, s)
                if r.user_id == myID, let sc = storedConversation(r.conversation_id) { sc.unread = 0; sc.markedUnread = false }
            }
            if let s = r.delivered_seq {
                deliveredMarks[r.conversation_id, default: [:]][r.user_id] = max(deliveredMarks[r.conversation_id]?[r.user_id] ?? 0, s)
            }
        case "typing":
            struct T: Decodable { var conversation_id: UUID; var user_id: UUID; var state: String }
            guard let t = ev.decode(T.self) else { return }
            if t.state == "stopped" {
                typing[t.conversation_id]?[t.user_id] = nil
            } else {
                typing[t.conversation_id, default: [:]][t.user_id] = TypingState(state: t.state, at: .now)
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    if let s = typing[t.conversation_id]?[t.user_id], Date.now.timeIntervalSince(s.at) >= 5.5 { typing[t.conversation_id]?[t.user_id] = nil }
                }
            }
        case "presence":
            struct P: Decodable { var user_id: UUID; var online: Bool; var last_seen_at: Date? }
            if let p = ev.decode(P.self) { presence[p.user_id] = (p.online, p.last_seen_at) }
        case "conversation.updated":
            struct C: Decodable { var conversation_id: UUID? ; var id: UUID? }
            if let c = ev.decode(C.self), let id = c.conversation_id ?? c.id { Task { await refreshConversation(id) } }
        case "conversation.removed":
            struct C: Decodable { var conversation_id: UUID }
            if let c = ev.decode(C.self) { removeLocal(c.conversation_id) }
        case "device.added", "keys.changed":
            deviceCache = [:]
        case "user.updated":
            if let u = ev.decode(User.self) { store(u) }
        case "call.ring":
            struct R: Decodable { var conversation_id: UUID; var caller_id: UUID; var caller_name: String; var video: Bool; var call_id: UUID }
            guard let r = ev.decode(R.self), r.caller_id != myID else { return }
            let call = IncomingCall(id: r.call_id, conversationID: r.conversation_id, callerID: r.caller_id, callerName: r.caller_name, video: r.video)
            incomingCall = call
            onIncomingCall?(call)
        case "call.ended":
            struct E: Decodable { var conversation_id: UUID }
            if let e = ev.decode(E.self) {
                if incomingCall?.conversationID == e.conversation_id { incomingCall = nil }
                onCallEnded?(e.conversation_id)
            }
        case "voice.state":
            if let st = ev.decode(VoiceRoomState.self) { voiceRooms[st.conversationID] = st.participants.isEmpty ? nil : st.participants }
        case "device.linked":
            struct L: Decodable { var name: String }
            if let l = ev.decode(L.self) { onDeviceLinked?(l.name) }
            Task { await shareHistoryKey() }
        default:
            break
        }
    }

    /// Applies one envelope to the local store.
    /// `openWith` opens with other keys (the history device's) instead of this device's.
    public func process(_ env: Envelope, live: Bool, countUnread: Bool = true, openWith: DeviceKeys? = nil) {
        if let c = env.cursor, !live, openWith == nil { cursor = max(cursor, c) }
        guard let keys = openWith ?? keys else { return }
        let fromMe = env.senderUserID == myID
        switch EnvelopeOpener(keys: keys).open(env, signingKey: env.senderDeviceID.flatMap(SigningKeyCache.get)) {
        case .system(let sys):
            guard existing(env.id) == nil else { return }
            let row = StoredMessage(id: env.id, clientID: env.clientID, conversationID: env.conversationID, seq: env.seq, sortKey: Double(env.seq),
                                    senderUserID: env.senderUserID, senderDeviceID: nil, sentAt: env.sentAt, status: .received, content: nil)
            row.system = sys
            context.insert(row)
            touchPreview(env.conversationID, text: SystemText.describe(sys, name: name), sender: nil, at: env.sentAt)
            if live { Task { await refreshConversation(env.conversationID) } }
        case .undecryptable:
            guard env.kind == "msg", openWith == nil else { return }
            if let row = existing(env.id) {
                if env.deleted { applyDelete(row) }
                return
            }
            let row = StoredMessage(id: env.id, clientID: env.clientID, conversationID: env.conversationID, seq: env.seq, sortKey: Double(env.seq),
                                    senderUserID: env.senderUserID, senderDeviceID: env.senderDeviceID, sentAt: env.sentAt,
                                    status: fromMe ? .sent : .received, content: nil, threadRootID: env.threadRootID)
            row.wasDeleted = env.deleted
            row.decryptFailed = !env.deleted
            row.expiresAt = env.expiresAt
            context.insert(row)
        case .content(let content, let verified):
            apply(env, content: content, verified: verified, live: live, countUnread: countUnread)
        }
    }

    func apply(_ env: Envelope, content: MessageContent, verified: Bool, live: Bool, countUnread: Bool) {
        let fromMe = env.senderUserID == myID
        switch env.kind {
        case "control":
            handleControl(env, content: content, live: live)
        case "msg":
            if content.type == .callKey { CallKeyStore.shared.put(room: content.callKey?.room, key: content.callKey?.key); return }
            let row: StoredMessage
            if let r = existing(env.id) ?? pending(clientID: env.clientID, device: env.senderDeviceID) {
                row = r
                row.id = env.id
                row.seq = env.seq
                row.sortKey = Double(env.seq)
                if row.status == .sending || row.status == .failed { row.status = .sent }
            } else {
                row = StoredMessage(id: env.id, clientID: env.clientID, conversationID: env.conversationID, seq: env.seq, sortKey: Double(env.seq),
                                    senderUserID: env.senderUserID, senderDeviceID: env.senderDeviceID, sentAt: env.sentAt,
                                    status: fromMe ? .sent : .received, content: content, threadRootID: env.threadRootID)
                context.insert(row)
                if let root = env.threadRootID, let parent = existing(root) { parent.replyCount += 1 }
                if !fromMe, countUnread, env.threadRootID == nil, env.conversationID != activeConversation, content.silent != true,
                   let sc = storedConversation(env.conversationID), live || env.seq > (sc.conversation?.me?.readSeq ?? 0) {
                    sc.unread += 1
                }
                if !fromMe, live, content.silent != true { onIncomingMessage?(row) }
            }
            row.content = content
            row.decryptFailed = false
            row.unverified = !verified
            row.expiresAt = env.expiresAt
            row.viewOnce = env.viewOnce || content.attachments?.contains { $0.viewOnce == true } == true
            if env.deleted { applyDelete(row) }
            applyPendingOps(for: row)
            if env.threadRootID == nil {
                touchPreview(env.conversationID, text: Self.preview(content), sender: env.senderUserID, at: env.sentAt)
            }
        case "edit", "delete", "reaction", "vote", "rsvp", "pin":
            guard let target = env.targetID else { return }
            if let row = existing(target) {
                applyOp(env.kind, content: content, sender: env.senderUserID, at: env.sentAt, to: row)
            } else {
                context.insert(PendingOp(id: env.id, targetID: target, kind: env.kind, senderUserID: env.senderUserID, content: content, sentAt: env.sentAt))
            }
        default:
            break
        }
    }

    func applyOp(_ kind: String, content: MessageContent?, sender: UUID?, at: Date, to row: StoredMessage) {
        switch kind {
        case "edit":
            guard sender == row.senderUserID, var c = row.content else { return }
            c.text = content?.text
            c.entities = content?.entities
            c.linkPreviews = content?.linkPreviews
            row.content = c
            row.editedAt = at
        case "delete":
            applyDelete(row)
        case "reaction":
            guard let sender else { return }
            var reactions = row.reactions.map { r in Reaction(emoji: r.emoji, userIDs: r.userIDs.filter { $0 != sender }) }.filter { !$0.userIDs.isEmpty }
            if let emoji = content?.emoji, !emoji.isEmpty {
                if let i = reactions.firstIndex(where: { $0.emoji == emoji }) { reactions[i].userIDs.append(sender) }
                else { reactions.append(Reaction(emoji: emoji, userIDs: [sender])) }
            }
            row.reactions = reactions
        case "vote":
            guard let sender else { return }
            var v = row.votes
            v[sender.lower] = content?.vote?.optionIDs ?? []
            row.votes = v
        case "rsvp":
            guard let sender else { return }
            var r = row.rsvps
            r[sender.lower] = content?.rsvp?.status.rawValue
            row.rsvps = r
        case "pin":
            row.isPinned = content?.pinned ?? true
        default:
            break
        }
    }

    func applyDelete(_ row: StoredMessage) {
        row.wasDeleted = true
        row.contentData = nil
        row.searchText = ""
        row.reactions = []
        if let atts = row.content?.attachments { atts.forEach { MediaCache.remove($0.mediaID) } }
    }

    func applyPendingOps(for row: StoredMessage) {
        let id = row.id
        let ops = (try? context.fetch(FetchDescriptor<PendingOp>(predicate: #Predicate { $0.targetID == id }, sortBy: [SortDescriptor(\.sentAt)]))) ?? []
        for op in ops {
            applyOp(op.kind, content: op.contentData.flatMap { try? JSONDecoder().decode(MessageContent.self, from: $0) }, sender: op.senderUserID, at: op.sentAt, to: row)
            context.delete(op)
        }
    }

    func existing(_ id: UUID) -> StoredMessage? {
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func pending(clientID: UUID, device: UUID?) -> StoredMessage? {
        guard device == myDeviceID else { return nil }
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.clientID == clientID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func touchPreview(_ conv: UUID, text: String, sender: UUID?, at: Date) {
        guard let sc = storedConversation(conv) else {
            Task { await refreshConversation(conv) }
            return
        }
        if sc.previewDate == nil || sc.previewDate! <= at {
            sc.previewText = text
            sc.previewSenderID = sender
            sc.previewDate = at
            sc.sortDate = max(sc.sortDate, at)
        }
    }

    nonisolated public static func preview(_ c: MessageContent) -> String {
        switch c.type {
        case .text: return c.text ?? ""
        case .media:
            let a = c.attachments ?? []
            let caption = c.text.map { " " + $0 } ?? ""
            if a.first?.viewOnce == true { return "View once photo" }
            if a.allSatisfy(\.isImage) { return (a.count > 1 ? "\(a.count) photos" : "Photo") + caption }
            if a.allSatisfy(\.isVideo) { return (a.count > 1 ? "\(a.count) videos" : "Video") + caption }
            return (a.first?.name ?? "File") + caption
        case .voice: return "Voice message"
        case .videoNote: return "Video message"
        case .location: return "Location"
        case .liveLocation: return "Live location"
        case .poll: return "Poll: " + (c.poll?.question ?? "")
        case .event: return "Event: " + (c.event?.title ?? "")
        case .sticker: return "Sticker"
        case .gif: return "GIF"
        case .contact: return "Contact"
        default: return c.text ?? "Message"
        }
    }

    // MARK: - Messages: sending

    struct AckFrame: Encodable, Sendable { var conversation_id: UUID; var seq: Int64 }
    struct ReadFrame: Encodable, Sendable { var conversation_id: UUID; var seq: Int64 }
    struct TypingFrame: Encodable, Sendable { var conversation_id: UUID; var state: String }

    public struct SendOptions: Sendable {
        public var replyTo: UUID?
        public var threadRootID: UUID?
        public var expiresIn: Int?
        public var sendAt: Date?
        public var viewOnce = false
        public var silent = false
        public init(replyTo: UUID? = nil, threadRootID: UUID? = nil, expiresIn: Int? = nil, sendAt: Date? = nil, viewOnce: Bool = false, silent: Bool = false) {
            self.replyTo = replyTo; self.threadRootID = threadRootID; self.expiresIn = expiresIn; self.sendAt = sendAt
            self.viewOnce = viewOnce; self.silent = silent
        }
    }

    /// Sends a displayable message, showing it immediately as "sending".
    @discardableResult
    public func send(_ content: MessageContent, to conv: UUID, options: SendOptions = .init(), clientID: UUID = UUID()) async -> StoredMessage {
        var content = content
        if let r = options.replyTo { content.replyTo = r }
        if options.silent { content.silent = true }
        let lastSeq = storedConversation(conv)?.conversation?.lastSeq ?? 0
        let row = StoredMessage(id: clientID, clientID: clientID, conversationID: conv, seq: 0, sortKey: Double(max(lastSeq, maxSeq(conv))) + 0.5 + Date.now.timeIntervalSince1970 / 1e12,
                                senderUserID: myID, senderDeviceID: myDeviceID, sentAt: .now, status: .sending, content: content, threadRootID: options.threadRootID)
        row.viewOnce = options.viewOnce
        if options.sendAt != nil { row.errorMessage = nil }
        context.insert(row)
        if options.threadRootID == nil { touchPreview(conv, text: Self.preview(content), sender: myID, at: .now) }
        if let root = options.threadRootID, let parent = existing(root) { parent.replyCount += 1 }
        storedConversation(conv)?.draft = ""
        try? context.save()
        await transmit(row, options: options)
        return row
    }

    func maxSeq(_ conv: UUID) -> Int64 {
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conv }, sortBy: [SortDescriptor(\.seq, order: .reverse)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.seq ?? 0
    }

    func transmit(_ row: StoredMessage, options: SendOptions) async {
        guard let content = row.content else { return }
        if isDemo {
            try? await Task.sleep(for: .milliseconds(350))
            row.status = .sent
            row.seq = maxSeq(row.conversationID) + 1
            row.sortKey = Double(row.seq)
            DemoData.autoReply(to: row, engine: self)
            try? context.save()
            return
        }
        do {
            let result = try await deliver(content, kind: "msg", to: row.conversationID, clientID: row.clientID, options: options)
            switch result {
            case .sent(let env):
                row.id = env.id
                row.seq = env.seq
                row.sortKey = Double(env.seq)
                row.expiresAt = env.expiresAt
                if row.status == .sending || row.status == .failed { row.status = .sent }
                applyPendingOps(for: row)
            case .scheduled(let at):
                // Keep it locally as a scheduled bubble until the server sends it.
                context.delete(row)
                banner = "Scheduled for \(at.formatted(date: .abbreviated, time: .shortened))"
            }
            row.errorMessage = nil
        } catch {
            row.status = .failed
            row.errorMessage = (error as? APIError)?.message ?? error.localizedDescription
        }
        try? context.save()
    }

    public func retry(_ row: StoredMessage) async {
        row.status = .sending
        await transmit(row, options: .init(threadRootID: row.threadRootID, viewOnce: row.viewOnce))
    }

    public enum SendResult: Sendable { case sent(Envelope), scheduled(Date) }

    struct SendResponse: Decodable, Sendable {
        var envelope: Envelope?
        var scheduledAt: Date?
        init(from decoder: Decoder) throws {
            struct S: Decodable { var scheduled_id: UUID; var send_at: Date }
            if let s = try? S(from: decoder) { scheduledAt = s.send_at } else { envelope = try Envelope(from: decoder) }
        }
    }

    /// Encrypts once, wraps the key for every device in the conversation and
    /// posts. Retries when the server reports the device set changed.
    func deliver(_ content: MessageContent, kind: String, to conv: UUID, target: UUID? = nil, clientID: UUID = UUID(), options: SendOptions = .init()) async throws -> SendResult {
        guard let api, let keys, let device = myDeviceID else { throw APIError.offline }
        let plaintext = try JSONEncoder().encode(content)
        let aad = E2EE.aad(conversation: conv, senderDevice: device, clientID: clientID)
        let sealed = try E2EE.seal(plaintext, aad: aad)
        let signature = try E2EE.sign(keys.signing, aad: aad, ciphertext: sealed.ciphertext)
        for attempt in 0..<3 {
            let devices = try await devicesFor(conv, refresh: attempt > 0)
            var wrapped: [String: Data] = [:]
            for d in devices {
                wrapped[d.id.lower] = try E2EE.wrap(sealed.key, for: d.identityKey, clientID: clientID)
            }
            let req = SendRequest(clientID: clientID, kind: kind, targetID: target, threadRootID: options.threadRootID, ciphertext: sealed.ciphertext,
                                  signature: signature, keys: wrapped, expiresIn: options.expiresIn, sendAt: options.sendAt, viewOnce: options.viewOnce)
            do {
                let res: SendResponse = try await api.send("POST", "/conversations/\(conv.lower)/messages", body: req)
                if let at = res.scheduledAt { return .scheduled(at) }
                if let env = res.envelope { return .sent(env) }
                throw APIError(status: 500, code: "bad_response", message: "Unexpected server response.")
            } catch let e as APIError where e.code == "device_mismatch" && attempt < 2 {
                continue
            }
        }
        throw APIError(status: 409, code: "device_mismatch", message: "Couldn't confirm everyone's devices. Try again.")
    }

    func devicesFor(_ conv: UUID, refresh: Bool) async throws -> [DeviceInfo] {
        if !refresh, let cached = deviceCache[conv] { return cached }
        guard let api else { throw APIError.offline }
        let devices = try await api.devices(in: conv)
        deviceCache[conv] = devices
        SigningKeyCache.put(devices)
        return devices
    }

    /// Sends a non-displayable operation (reaction, edit, delete, vote, rsvp, pin).
    func sendOp(_ kind: String, content: MessageContent, target: StoredMessage) async {
        applyOp(kind, content: content, sender: myID, at: .now, to: target)
        try? context.save()
        guard !isDemo else { return }
        do {
            _ = try await deliver(content, kind: kind, to: target.conversationID, target: target.id)
        } catch {
            banner = (error as? APIError)?.message ?? "Couldn't send. Check your connection."
        }
    }

    public func react(_ emoji: String, to row: StoredMessage) async {
        let mine = row.reactions.first { $0.userIDs.contains(myID ?? UUID()) }?.emoji
        await sendOp("reaction", content: .reaction(mine == emoji ? "" : emoji, to: row.id), target: row)
    }

    public func edit(_ row: StoredMessage, text: String) async {
        var c = MessageContent(type: .edit, text: text)
        c.target = row.id
        await sendOp("edit", content: c, target: row)
    }

    public func deleteForEveryone(_ row: StoredMessage) async {
        var c = MessageContent(type: .delete)
        c.target = row.id
        await sendOp("delete", content: c, target: row)
    }

    public func deleteForMe(_ row: StoredMessage) {
        context.delete(row)
        try? context.save()
    }

    public func vote(_ options: [String], on row: StoredMessage) async {
        var c = MessageContent(type: .vote)
        c.vote = .init(optionIDs: options)
        c.target = row.id
        await sendOp("vote", content: c, target: row)
    }

    public func rsvp(_ status: MessageContent.RSVP.Status, on row: StoredMessage) async {
        var c = MessageContent(type: .rsvp)
        c.rsvp = .init(status: status)
        c.target = row.id
        await sendOp("rsvp", content: c, target: row)
    }

    public func pin(_ row: StoredMessage, pinned: Bool) async {
        var c = MessageContent(type: .systemNote)
        c.pinned = pinned
        c.target = row.id
        await sendOp("pin", content: c, target: row)
    }

    public func forward(_ row: StoredMessage, to convs: [UUID]) async {
        guard var c = row.content else { return }
        c.forwarded = true
        c.replyTo = nil
        for conv in convs { await send(c, to: conv) }
    }

    public func markViewedOnce(_ row: StoredMessage) {
        row.viewedOnce = true
        row.content?.attachments?.forEach { MediaCache.remove($0.mediaID) }
        try? context.save()
    }

    public func markRead(_ conv: UUID) {
        guard let sc = storedConversation(conv) else { return }
        let seq = maxSeq(conv)
        sc.unread = 0
        sc.markedUnread = false
        try? context.save()
        guard seq > 0, !isDemo else { return }
        if connection == .connected {
            realtime?.send(type: "read", data: ReadFrame(conversation_id: conv, seq: seq))
        } else {
            struct Body: Encodable, Sendable { var seq: Int64 }
            Task { try? await api?.call("POST", "/conversations/\(conv.lower)/read", body: Body(seq: seq)) }
        }
    }

    public func markUnread(_ conv: UUID) {
        storedConversation(conv)?.markedUnread = true
        try? context.save()
    }

    public func setTyping(_ conv: UUID, state: String = "typing") {
        guard !isDemo else { return }
        if state != "stopped", let last = lastTypingSent[conv], Date.now.timeIntervalSince(last) < 3 { return }
        lastTypingSent[conv] = state == "stopped" ? nil : .now
        realtime?.send(type: "typing", data: TypingFrame(conversation_id: conv, state: state))
    }

    public func status(of row: StoredMessage) -> MessageStatus {
        guard row.senderUserID == myID, row.status == .sent || row.status == .delivered || row.status == .read else { return row.status }
        let others = { (marks: [UUID: Int64]?) in (marks ?? [:]).filter { $0.key != self.myID }.values }
        if others(readMarks[row.conversationID]).contains(where: { $0 >= row.seq }) { return .read }
        if others(deliveredMarks[row.conversationID]).contains(where: { $0 >= row.seq }) { return .delivered }
        return .sent
    }

    // MARK: - Attachments

    public struct OutgoingFile: Sendable {
        public var data: Data
        public var mime: String
        public var name: String?
        public var width: Int?
        public var height: Int?
        public var durationMS: Int?
        public var waveform: Data?
        public var thumbnail: Data?
        public init(data: Data, mime: String, name: String? = nil, width: Int? = nil, height: Int? = nil, durationMS: Int? = nil,
                    waveform: Data? = nil, thumbnail: Data? = nil) {
            self.data = data; self.mime = mime; self.name = name; self.width = width; self.height = height
            self.durationMS = durationMS; self.waveform = waveform; self.thumbnail = thumbnail
        }
    }

    /// Encrypts and uploads files, then sends them as one message.
    public func sendFiles(_ files: [OutgoingFile], type: MessageContent.Kind = .media, caption: String? = nil, to conv: UUID, options: SendOptions = .init()) async {
        let clientID = UUID()
        // Show placeholders straight away from local copies.
        var placeholders: [MessageContent.Attachment] = []
        for f in files {
            let tempID = UUID()
            MediaCache.store(f.data, for: tempID)
            placeholders.append(.init(mediaID: tempID, mime: f.mime, size: f.data.count, name: f.name, key: Data(), digest: Data(),
                                      width: f.width, height: f.height, durationMS: f.durationMS, waveform: f.waveform, thumbnail: f.thumbnail,
                                      viewOnce: options.viewOnce ? true : nil))
        }
        var content = MessageContent(type: type, text: caption)
        content.attachments = placeholders
        if isDemo {
            await send(content, to: conv, options: options, clientID: clientID)
            return
        }
        let lastSeq = Double(maxSeq(conv))
        let row = StoredMessage(id: clientID, clientID: clientID, conversationID: conv, seq: 0, sortKey: lastSeq + 0.5 + Date.now.timeIntervalSince1970 / 1e12,
                                senderUserID: myID, senderDeviceID: myDeviceID, sentAt: .now, status: .sending, content: content, threadRootID: options.threadRootID)
        context.insert(row)
        touchPreview(conv, text: Self.preview(content), sender: myID, at: .now)
        try? context.save()
        guard let api else { return }
        do {
            var uploaded: [MessageContent.Attachment] = []
            let ttl = options.expiresIn ?? storedConversation(conv)?.conversation.map { $0.disappearingSeconds > 0 ? $0.disappearingSeconds : 0 }
            for (i, f) in files.enumerated() {
                let enc = try await Task.detached(priority: .userInitiated) { try MediaCrypto.encrypt(f.data) }.value
                let id = try await api.upload(enc.blob, ttl: (ttl ?? 0) > 0 ? ttl : nil)
                MediaCache.move(from: placeholders[i].mediaID, to: id)
                var a = placeholders[i]
                a.mediaID = id
                a.key = enc.key
                a.digest = enc.digest
                uploaded.append(a)
            }
            content.attachments = uploaded
            row.content = content
            try? context.save()
            await transmit(row, options: options)
        } catch {
            row.status = .failed
            row.errorMessage = (error as? APIError)?.message ?? "Upload failed."
            try? context.save()
        }
    }

    /// Returns decrypted attachment bytes, downloading if needed.
    public func attachmentData(_ a: MessageContent.Attachment) async throws -> Data {
        if let cached = MediaCache.data(for: a.mediaID) { return cached }
        guard let api else { throw APIError.offline }
        let blob = try await api.download(a.mediaID)
        let plain = try await Task.detached(priority: .userInitiated) { try MediaCrypto.decrypt(blob, key: a.key, digest: a.digest) }.value
        MediaCache.store(plain, for: a.mediaID)
        return plain
    }

    public func avatarURL(_ id: UUID?) -> URL? {
        guard let id, let api else { return nil }
        return api.mediaURL(id)
    }

    // MARK: - Calls

    public func startCall(_ conv: UUID, video: Bool) async throws -> CallJoin {
        guard let api else { throw APIError.offline }
        struct Body: Encodable, Sendable { var video: Bool }
        let join: CallJoin = try await api.send("POST", "/conversations/\(conv.lower)/calls", body: Body(video: video))
        if !join.joinedExisting {
            // Distribute a fresh E2EE media key to everyone in the call.
            let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            CallKeyStore.shared.put(room: join.room, key: key)
            var c = MessageContent(type: .callKey)
            c.callKey = .init(room: join.room, key: key)
            _ = try? await deliver(c, kind: "control", to: conv)
        }
        return join
    }

    public func endCall(_ conv: UUID, reason: String, all: Bool) async {
        struct Body: Encodable, Sendable { var reason: String; var all: Bool }
        try? await api?.call("POST", "/conversations/\(conv.lower)/calls/end", body: Body(reason: reason, all: all))
    }

    public func recordCall(_ conv: UUID, video: Bool, outgoing: Bool, duration: TimeInterval, missed: Bool) {
        context.insert(StoredCall(conversationID: conv, startedAt: .now.addingTimeInterval(-duration), duration: duration, video: video, outgoing: outgoing, missed: missed))
        try? context.save()
    }

    // MARK: - Push

    /// APNs environment of this build: Xcode builds use the sandbox.
    nonisolated public static var pushEnvironment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    public func registerPush(token: Data?, voipToken: Data?) async {
        guard let api else { return }
        struct Body: Encodable, Sendable { var kind: String; var token: String; var voip_token: String; var env: String }
        let hex = { (d: Data?) in d?.map { String(format: "%02x", $0) }.joined() ?? "" }
        if let token { AppGroup.defaults.set(hex(token), forKey: "apnsToken") }
        if let voipToken { AppGroup.defaults.set(hex(voipToken), forKey: "voipToken") }
        let apns = AppGroup.defaults.string(forKey: "apnsToken") ?? "", voip = AppGroup.defaults.string(forKey: "voipToken") ?? ""
        if serverInfo == nil { serverInfo = try? await api.info() }
        // Servers that use the Asgard push relay only ever get opaque handles, never device tokens.
        if let relay = serverInfo?.pushRelay, let url = URL(string: relay.url) {
            let handle = await relayHandle(url, server: relay.serverID, token: apns)
            let voipHandle = await relayHandle(url, server: relay.serverID, token: voip)
            if handle != nil || voipHandle != nil {
                try? await api.call("PUT", "/me/push", body: Body(kind: "relay", token: handle ?? "", voip_token: voipHandle ?? "", env: Self.pushEnvironment))
                return
            }
        }
        try? await api.call("PUT", "/me/push", body: Body(kind: "apns", token: apns, voip_token: voip, env: Self.pushEnvironment))
    }

    /// Exchanges an APNs token for a relay handle bound to this server.
    func relayHandle(_ relay: URL, server: String, token: String) async -> String? {
        guard !token.isEmpty else { return nil }
        struct Body: Encodable, Sendable { var server_id: String; var platform = "apns"; var token: String; var env: String }
        struct Out: Decodable, Sendable { var handle: String }
        var req = URLRequest(url: relay.appending(path: "v1/devices"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Body(server_id: server, token: token, env: Self.pushEnvironment))
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 201 else { return nil }
        return (try? JSONDecoder().decode(Out.self, from: data))?.handle
    }

    // MARK: - Maintenance

    func expiryLoop() async {
        while !Task.isCancelled {
            purgeExpired()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    public func purgeExpired() {
        let now = Date.now
        let expired = (try? context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.expiresAt != nil && $0.expiresAt! < now }))) ?? []
        guard !expired.isEmpty else { return }
        for row in expired {
            row.content?.attachments?.forEach { MediaCache.remove($0.mediaID) }
            context.delete(row)
        }
        try? context.save()
    }
}

/// Room keys for E2EE calls, received in encrypted `call_key` messages.
public final class CallKeyStore: @unchecked Sendable {
    public static let shared = CallKeyStore()
    private var keys: [String: Data] = [:]
    private let lock = NSLock()
    public func put(room: String?, key: Data?) {
        guard let room, let key else { return }
        lock.withLock { keys[room] = key }
    }
    public func key(for room: String) -> Data? { lock.withLock { keys[room] } }
}
