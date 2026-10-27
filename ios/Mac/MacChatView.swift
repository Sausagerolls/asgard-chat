import AppKit
import AsgardKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// State for one open conversation (reply target, editing, scroll requests).
@MainActor
@Observable
final class MacChatState {
    var replyTo: StoredMessage?
    var editing: StoredMessage?
    var scrollTarget: UUID?
    var dropping = false
}

struct MacChatView: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(MacCallManager.self) private var calls
    @Environment(MacNavigator.self) private var nav
    @Environment(Appearance.self) private var appearance
    @State private var state = MacChatState()

    var stored: StoredConversation? { engine.storedConversation(conversationID) }

    var body: some View {
        let kind = stored?.kind ?? .group
        ZStack {
            ChatWallpaper(wallpaper: Wallpaper(rawValue: stored?.wallpaper ?? "") ?? appearance.wallpaper, animated: appearance.animatedBackgrounds)
            MacMessageList(conversationID: conversationID, kind: kind)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if kind.hasVoiceRoom {
                MacVoiceRoomBar(conversationID: conversationID).padding(.horizontal, 14).padding(.top, 8)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacComposer(conversationID: conversationID, canPost: canPost)
        }
        .overlay {
            if state.dropping {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 20))
                    .overlay(Label("Drop to send", systemImage: "arrow.down.doc").font(.title2.bold()))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $state.dropping) { providers in
            Task { await sendDropped(providers) }
            return true
        }
        .environment(state)
        .navigationTitle(stored?.title ?? "")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if kind == .dm {
                    Button { Task { await calls.startCall(conversationID, video: false) } } label: { Image(systemName: "phone") }.help("Voice Call")
                    Button { Task { await calls.startCall(conversationID, video: true) } } label: { Image(systemName: "video") }.help("Video Call")
                } else if kind.hasVoiceRoom {
                    Button { Task { await calls.joinVoiceRoom(conversationID, video: false) } } label: { Image(systemName: "speaker.wave.2") }
                        .help("Join Voice Room")
                }
                Button { nav.showInspector.toggle() } label: { Image(systemName: "info.circle") }.help("Chat Info (⌘I)")
            }
        }
        .onAppear {
            engine.activeConversation = conversationID
            engine.markRead(conversationID)
        }
        .onDisappear { if engine.activeConversation == conversationID { engine.activeConversation = nil } }
    }

    var canPost: Bool {
        guard let c = stored?.conversation else { return true }
        if c.kind != .channel { return true }
        let role = c.me?.role
        return role == .owner || role == .admin
    }

    var subtitle: String {
        guard let s = stored, let c = s.conversation else { return "" }
        if let t = engine.typing[conversationID]?.first {
            return s.kind == .dm ? "typing…" : "\(engine.name(t.key)) is typing…"
        }
        switch s.kind {
        case .dm:
            guard let peer = c.peer else { return "" }
            if engine.presence[peer.id]?.online ?? peer.online { return "online" }
            if let seen = engine.presence[peer.id]?.lastSeen ?? peer.lastSeenAt { return "last seen " + seen.formatted(.relative(presentation: .named)) }
            return ""
        case .channel: return "\(c.memberCount) subscribers"
        default: return "\(c.memberCount) members"
        }
    }

    func sendDropped(_ providers: [NSItemProvider]) async {
        var files: [ChatEngine.OutgoingFile] = []
        for p in providers {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let fileURL = URL(dataRepresentation: url, relativeTo: nil), let f = MacFiles.outgoing(fileURL) {
                files.append(f)
            } else if let data = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) as? Data, let f = MacFiles.outgoingImage(data) {
                files.append(f)
            }
        }
        if !files.isEmpty { await engine.sendFiles(files, to: conversationID) }
    }
}

struct MacMessageList: View {
    let conversationID: UUID
    let kind: ConversationKind
    @Environment(ChatEngine.self) private var engine
    @Environment(MacChatState.self) private var state
    @Environment(Appearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var messages: [StoredMessage]
    @State private var atBottom = true
    @State private var opened = Date.now
    @State private var initial: Set<UUID>?

    init(conversationID: UUID, kind: ConversationKind) {
        self.conversationID = conversationID
        self.kind = kind
        _messages = Query(filter: #Predicate<StoredMessage> { $0.conversationID == conversationID && $0.threadRootID == nil }, sort: \StoredMessage.sortKey)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 1).onAppear { Task { if messages.count >= 30 { await engine.loadOlder(conversationID) } } }
                    ForEach(Array(messages.enumerated()), id: \.element.clientID) { i, m in
                        let prev = i > 0 ? messages[i - 1] : nil
                        let next = i + 1 < messages.count ? messages[i + 1] : nil
                        if prev == nil || !Calendar.current.isDate(prev!.sentAt, inSameDayAs: m.sentAt) {
                            Text(m.sentAt.macDaySeparator).font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .glassEffect(.regular, in: .capsule).padding(.vertical, 10)
                        }
                        let first = prev.map { !joins($0, m) } ?? true
                        let last = next.map { !joins(m, $0) } ?? true
                        MacMessageRow(message: m, isGroup: kind != .dm && kind != .saved, first: first, last: last,
                                      arriving: animate && isArrival(m))
                            .id(m.id)
                            .padding(.top, first ? 8 : 0)
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - 120 } action: { _, b in atBottom = b }
            .onChange(of: messages.count) { old, new in
                guard new > old, let last = messages.last else { return }
                if atBottom || last.senderUserID == engine.myID { withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } }
                if NSApp.isActive { engine.markRead(conversationID) }
            }
            .onChange(of: state.scrollTarget) { _, t in
                guard let t else { return }
                withAnimation(.smooth) { proxy.scrollTo(t, anchor: .center) }
                state.scrollTarget = nil
            }
            .task {
                initial = Set(messages.map(\.clientID))
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "chevron.down").font(.headline).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).padding(16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
        }
    }

    var animate: Bool { appearance.messageAnimations && !reduceMotion }

    func isArrival(_ m: StoredMessage) -> Bool {
        guard let initial else { return false }
        return !initial.contains(m.clientID) && m.sentAt > opened.addingTimeInterval(-2)
    }

    func joins(_ a: StoredMessage, _ b: StoredMessage) -> Bool {
        !a.isSystem && !b.isSystem && a.senderUserID == b.senderUserID && b.sentAt.timeIntervalSince(a.sentAt) < 180
    }
}

struct MacMessageRow: View {
    let message: StoredMessage
    let isGroup: Bool
    let first: Bool
    let last: Bool
    @Environment(ChatEngine.self) private var engine
    @Environment(MacChatState.self) private var state
    @Environment(Appearance.self) private var appearance
    @State private var hovering = false
    @State private var landed: Bool

    init(message: StoredMessage, isGroup: Bool, first: Bool, last: Bool, arriving: Bool) {
        self.message = message
        self.isGroup = isGroup
        self.first = first
        self.last = last
        _landed = State(initialValue: !arriving)
    }

    var mine: Bool { message.senderUserID == engine.myID }

    var body: some View {
        if message.isSystem {
            Text(message.system.map { SystemText.describe($0, name: engine.name) } ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule).padding(.vertical, 4)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 80) }
                if !mine && isGroup {
                    if last {
                        AvatarView(id: message.senderUserID, name: engine.name(message.senderUserID),
                                   mediaID: engine.user(message.senderUserID)?.avatarMediaID, size: 28)
                    } else { Color.clear.frame(width: 28, height: 1) }
                }
                if mine { actions }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if isGroup && !mine && first {
                        Text(engine.name(message.senderUserID)).font(.caption.weight(.semibold))
                            .foregroundStyle(Color.identity(message.senderUserID)).padding(.leading, 12)
                    }
                    MacBubble(message: message, mine: mine, tail: last)
                    if !message.reactions.isEmpty { reactionStrip }
                }
                if !mine { actions }
                if !mine { Spacer(minLength: 80) }
            }
            .scaleEffect(landed ? 1 : 0.6, anchor: mine ? .bottomTrailing : .bottomLeading)
            .offset(x: landed || mine ? 0 : -30, y: landed ? 0 : (mine ? 50 : 14))
            .opacity(landed ? 1 : 0)
            // Start from the hidden state for one frame so AppKit renders it before animating.
            .task {
                guard !landed else { return }
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { landed = true }
            }
            .scrollTransition(topLeading: .interactive, bottomTrailing: .interactive) { view, phase in
                view.scaleEffect(phase.isIdentity ? 1 : 0.94, anchor: mine ? .trailing : .leading)
                    .opacity(phase.isIdentity ? 1 : 0.4)
                    .blur(radius: phase.isIdentity ? 0 : 1.5)
            }
            .onHover { hovering = $0 }
            .contextMenu { MacMessageMenu(message: message) }
        }
    }

    /// Hover toolbar: quick reactions, reply, more.
    var actions: some View {
        HStack(spacing: 2) {
            ForEach(["❤️", "👍", "😂"], id: \.self) { e in
                Button(e) { Task { await engine.react(e, to: message) } }.buttonStyle(.borderless)
            }
            Button { state.replyTo = message } label: { Image(systemName: "arrowshape.turn.up.left") }.buttonStyle(.borderless).help("Reply")
            Menu { MacMessageMenu(message: message) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .padding(.bottom, 6)
    }

    var reactionStrip: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { r in
                let mineR = r.userIDs.contains { $0 == engine.myID }
                Button { Task { await engine.react(r.emoji, to: message) } } label: {
                    Text("\(r.emoji) \(r.userIDs.count)").font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(mineR ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.18), in: .capsule)
                }
                .buttonStyle(.plain)
                .help(r.userIDs.map { engine.name($0) }.joined(separator: ", "))
            }
        }
    }
}

struct MacBubble: View {
    let message: StoredMessage
    let mine: Bool
    let tail: Bool
    @Environment(ChatEngine.self) private var engine
    @Environment(Appearance.self) private var appearance
    @Environment(MacChatState.self) private var state

    var body: some View {
        let content = message.content
        VStack(alignment: .leading, spacing: 6) {
            if let reply = content?.replyTo, let target = engine.messageRow(reply) {
                Button { state.scrollTarget = target.id } label: {
                    HStack(spacing: 6) {
                        Capsule().fill(mine ? Color.white.opacity(0.7) : Color.identity(target.senderUserID)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(engine.name(target.senderUserID)).font(.caption.weight(.semibold))
                            Text(target.content.map(ChatEngine.preview) ?? "").font(.caption).lineLimit(1).opacity(0.8)
                        }
                    }
                    .padding(6)
                    .background(.black.opacity(0.12), in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            if content?.forwarded == true {
                Label("Forwarded", systemImage: "arrowshape.turn.up.right").font(.caption).opacity(0.7)
            }
            if message.wasDeleted {
                Label("Message deleted", systemImage: "nosign").italic().opacity(0.7)
            } else if message.decryptFailed {
                Label("Couldn't decrypt this message", systemImage: "lock.trianglebadge.exclamationmark").opacity(0.8)
            } else if let c = content {
                MacContentBody(message: message, content: c, mine: mine)
            }
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if message.editedAt != nil { Text("edited") }
                if message.isStarred { Image(systemName: "star.fill") }
                Text(message.sentAt, style: .time)
                if mine { MacStatusIcon(status: engine.status(of: message)) }
            }
            .font(.caption2).opacity(0.65)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(mine ? Color.white : Color.primary)
        .background(mine ? appearance.accent.fill : AnyShapeStyle(.regularMaterial), in: bubbleShape)
        .frame(maxWidth: 560, alignment: mine ? .trailing : .leading)
        .textSelection(.enabled)
    }

    var bubbleShape: UnevenRoundedRectangle {
        let big: CGFloat = 18, small: CGFloat = tail && appearance.bubbles == .tailed ? 5 : 18
        return mine
            ? UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big, bottomTrailingRadius: small, topTrailingRadius: big, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: small, bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }
}

struct MacStatusIcon: View {
    let status: MessageStatus
    var body: some View {
        switch status {
        case .sending: Image(systemName: "clock")
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .read: Image(systemName: "checkmark.circle.fill")
        case .delivered: Image(systemName: "checkmark.circle")
        default: Image(systemName: "checkmark")
        }
    }
}

struct MacContentBody: View {
    let message: StoredMessage
    let content: MessageContent
    let mine: Bool
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        switch content.type {
        case .media, .voice, .videoNote, .gif, .sticker:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.attachments ?? [], id: \.mediaID) { a in MacAttachmentView(message: message, attachment: a, mine: mine) }
                if let t = content.text, !t.isEmpty { Text(t) }
            }
        case .poll:
            if let poll = content.poll { MacPollView(message: message, poll: poll, mine: mine) }
        case .event:
            if let e = content.event {
                VStack(alignment: .leading, spacing: 4) {
                    Label(e.title, systemImage: "calendar").font(.headline)
                    Text(e.startsAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                    if let l = e.location { Label(l, systemImage: "mappin").font(.caption) }
                    HStack {
                        ForEach([("Going", MessageContent.RSVP.Status.yes), ("Maybe", .maybe), ("Can't go", .no)], id: \.0) { title, st in
                            let n = message.rsvps.values.filter { $0 == st.rawValue }.count
                            Button("\(title)\(n > 0 ? " · \(n)" : "")") { Task { await engine.rsvp(st, on: message) } }.controlSize(.small)
                        }
                    }
                }
            }
        case .location, .liveLocation:
            if let l = content.location {
                Link(destination: URL(string: "https://maps.apple.com/?ll=\(l.lat),\(l.lon)")!) {
                    Label(l.name ?? "Location", systemImage: "mappin.and.ellipse")
                }
            }
        default:
            Text(attributed(content.text ?? ChatEngine.preview(content)))
            ForEach(content.linkPreviews ?? [], id: \.url) { p in
                Link(destination: URL(string: p.url) ?? URL(string: "https://example.com")!) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = p.title { Text(t).font(.callout.weight(.semibold)) }
                        if let d = p.description { Text(d).font(.caption).lineLimit(2) }
                        Text(URL(string: p.url)?.host() ?? "").font(.caption2).opacity(0.7)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.12), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct MacPollView: View {
    let message: StoredMessage
    let poll: MessageContent.Poll
    let mine: Bool
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        let votes = message.votes
        let total = max(1, votes.count)
        let myVotes = votes[engine.myID?.lower ?? ""] ?? []
        VStack(alignment: .leading, spacing: 8) {
            Label(poll.question, systemImage: "chart.bar.fill").font(.headline)
            ForEach(poll.options, id: \.id) { o in
                let n = votes.values.filter { $0.contains(o.id) }.count
                Button {
                    var next = poll.multiple ? myVotes : []
                    if myVotes.contains(o.id) { next.removeAll { $0 == o.id } } else { next.append(o.id) }
                    Task { await engine.vote(next, on: message) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: myVotes.contains(o.id) ? "checkmark.circle.fill" : "circle")
                            Text(o.text)
                            Spacer()
                            Text("\(Int(Double(n) / Double(total) * 100))%").monospacedDigit().font(.caption)
                        }
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.2))
                                .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * Double(n) / Double(total)) }
                        }
                        .frame(height: 5)
                    }
                }
                .buttonStyle(.plain)
            }
            Text("\(votes.count) votes").font(.caption).opacity(0.7)
        }
        .frame(minWidth: 260)
    }
}

struct MacMessageMenu: View {
    let message: StoredMessage
    @Environment(ChatEngine.self) private var engine
    @Environment(MacChatState.self) private var state

    var body: some View {
        let mine = message.senderUserID == engine.myID
        Button("Reply") { state.replyTo = message }
        if let t = message.content?.text, !t.isEmpty {
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        }
        Menu("React") {
            ForEach(["❤️", "👍", "😂", "😮", "😢", "🔥", "⚡️", "🙏"], id: \.self) { e in Button(e) { Task { await engine.react(e, to: message) } } }
        }
        if mine, message.content?.type == .text { Button("Edit") { state.editing = message } }
        Button(message.isPinned ? "Unpin" : "Pin") { Task { await engine.pin(message, pinned: !message.isPinned) } }
        Button(message.isStarred ? "Unstar" : "Star") { message.isStarred.toggle(); try? engine.context.save() }
        if message.status == .failed { Button("Retry Sending") { Task { await engine.retry(message) } } }
        Divider()
        if mine { Button("Delete for Everyone", role: .destructive) { Task { await engine.deleteForEveryone(message) } } }
        Button("Delete on This Mac", role: .destructive) { engine.deleteForMe(message) }
    }
}

extension ChatEngine {
    func messageRow(_ id: UUID) -> StoredMessage? {
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }
}

extension Date {
    var macDaySeparator: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return formatted(date: .complete, time: .omitted)
    }
}
