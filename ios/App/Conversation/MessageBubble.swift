import AsgardKit
import SwiftData
import SwiftUI

/// A message with avatar, selection, swipe-to-reply and the context menu.
struct MessageRow: View {
    let message: StoredMessage
    let grouping: Grouping
    let isGroup: Bool
    var isChannel = false
    @Environment(ChatEngine.self) private var engine
    @Environment(ChatSession.self) private var session
    @State private var dragX: CGFloat = 0
    @State private var triggered = false

    var mine: Bool { message.senderUserID == engine.myID }

    var body: some View {
        if message.isSystem {
            SystemMessageView(message: message)
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if session.selecting {
                    Image(systemName: session.selected.contains(message.clientID) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(session.selected.contains(message.clientID) ? Color.accentColor : .secondary)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if isGroup && !mine && !isChannel {
                    if grouping.showsTail {
                        let u = engine.user(message.senderUserID)
                        AvatarView(id: message.senderUserID, name: u?.displayName ?? "?", mediaID: u?.avatarMediaID, size: 30)
                    } else {
                        Color.clear.frame(width: 30, height: 1)
                    }
                }
                if mine { Spacer(minLength: 48) }
                MessageBubble(message: message, grouping: grouping, isGroup: isGroup && !isChannel)
                    .offset(x: dragX)
                    .contextMenu { MessageMenu(message: message) }
                    .onTapGesture(count: 2) {
                        Haptics.tap()
                        Task { await engine.react("❤️", to: message) }
                    }
                if !mine { Spacer(minLength: 48) }
            }
            .background(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(.secondary)
                    .opacity(Double(min(dragX / 60, 1)))
                    .scaleEffect(triggered ? 1.2 : 0.8)
                    .padding(.leading, 4)
            }
            .contentShape(.rect)
            .onTapGesture {
                guard session.selecting else { return }
                if session.selected.contains(message.clientID) { session.selected.remove(message.clientID) } else { session.selected.insert(message.clientID) }
            }
            .simultaneousGesture(swipeToReply)
            .background {
                if session.highlight == message.id {
                    RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, -6)
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: session.highlight)
            .animation(.snappy, value: session.selecting)
        }
    }

    var swipeToReply: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard !session.selecting, !message.wasDeleted, abs(v.translation.height) < 40, v.translation.width > 0 else { return }
                dragX = min(v.translation.width * 0.6, 80)
                if dragX > 56 && !triggered { triggered = true; Haptics.tap() }
            }
            .onEnded { _ in
                if triggered { session.replyTo = message; session.editing = nil }
                withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                triggered = false
            }
    }
}

struct MessageMenu: View {
    let message: StoredMessage
    @Environment(ChatEngine.self) private var engine
    @Environment(ChatSession.self) private var session

    var mine: Bool { message.senderUserID == engine.myID }
    var perms: Permissions { engine.conversation(message.conversationID)?.me?.permissions ?? [] }

    var body: some View {
        if !message.wasDeleted {
            ControlGroup {
                ForEach(["❤️", "👍", "😂", "😮", "😢", "🔥"], id: \.self) { e in
                    Button(e) { Task { await engine.react(e, to: message) } }
                }
            }
            .controlGroupStyle(.compactMenu)
            Button { session.reacting = message } label: { Label("More reactions", systemImage: "face.smiling") }
            Button { session.replyTo = message; session.editing = nil } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button { session.threadRoot = message } label: { Label("Reply in thread", systemImage: "bubble.left.and.text.bubble.right") }
            if let text = message.content?.text, !text.isEmpty {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { session.translateText = text } label: { Label("Translate", systemImage: "translate") }
                if mine && message.content?.type == .text && message.sentAt.timeIntervalSinceNow > -48 * 3600 {
                    Button { session.editing = message; session.replyTo = nil } label: { Label("Edit", systemImage: "pencil") }
                }
            }
            if let a = message.content?.attachments?.first, a.isImage || a.isVideo, !message.viewOnce {
                Button { Task { await MediaSaver.save(a, engine: engine) } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
            }
            Button { session.forwarding = [message] } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            if perms.contains(.pin) {
                Button { Task { await engine.pin(message, pinned: !message.isPinned) } } label: {
                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
                }
            }
            Button { message.isStarred.toggle(); try? engine.context.save() } label: {
                Label(message.isStarred ? "Unstar" : "Star", systemImage: message.isStarred ? "star.slash" : "star")
            }
            Button { session.selecting = true; session.selected = [message.clientID] } label: { Label("Select", systemImage: "checkmark.circle") }
            if mine { Button { session.infoFor = message } label: { Label("Info", systemImage: "info.circle") } }
            if message.status == .failed { Button { Task { await engine.retry(message) } } label: { Label("Retry", systemImage: "arrow.clockwise") } }
        }
        Divider()
        Button(role: .destructive) { engine.deleteForMe(message) } label: { Label("Delete for me", systemImage: "trash") }
        if !message.wasDeleted && (mine || perms.contains(.deleteOthers)) && message.status != .failed {
            Button(role: .destructive) { Task { await engine.deleteForEveryone(message) } } label: { Label("Delete for everyone", systemImage: "trash.fill") }
        }
    }
}

/// The bubble itself. Also used by the chat preview.
struct MessageBubble: View {
    let message: StoredMessage
    let grouping: Grouping
    let isGroup: Bool
    var compact = false
    @Environment(ChatEngine.self) private var engine
    @Environment(Appearance.self) private var appearance

    var mine: Bool { message.senderUserID == engine.myID }
    var content: MessageContent? { message.content }

    var isJumbo: Bool {
        guard content?.type == .text, content?.replyTo == nil, let t = content?.text, t.count <= 8 else { return false }
        return t.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C || $0 == "\u{200D}" || $0 == "\u{FE0F}" }
    }

    var bare: Bool { isJumbo || content?.type == .sticker || content?.type == .videoNote }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 4) {
                if isGroup && !mine && grouping.showsName {
                    Text(engine.name(message.senderUserID)).font(.caption.weight(.semibold)).foregroundStyle(Color.identity(message.senderUserID))
                }
                if content?.forwarded == true {
                    Label("Forwarded", systemImage: "arrowshape.turn.up.right.fill").font(.caption2.italic()).foregroundStyle(secondaryText)
                }
                if let r = content?.replyTo { ReplyQuote(targetID: r, onBubble: !bare, mine: mine) }
                bodyContent
                footer
            }
            .padding(.horizontal, bare ? 0 : 12)
            .padding(.vertical, bare ? 0 : 8)
            .foregroundStyle(mine && !bare ? Color.white : Color.primary)
            .background { if !bare { bubbleBackground } }
            .frame(maxWidth: compact ? 260 : 320, alignment: mine ? .trailing : .leading)

            if !message.reactions.isEmpty { ReactionsBar(message: message, mine: mine) }
            if message.replyCount > 0 { ThreadButton(message: message) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    var secondaryText: Color { mine ? .white.opacity(0.75) : .secondary }

    @ViewBuilder var bubbleBackground: some View {
        let shape = BubbleShape(mine: mine, tail: appearance.bubbles == .tailed && grouping.showsTail, style: appearance.bubbles)
        if mine {
            shape.fill(appearance.accent.fill)
        } else {
            shape.fill(.regularMaterial).overlay(shape.stroke(.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder var bodyContent: some View {
        if message.wasDeleted {
            Label("This message was deleted", systemImage: "nosign").font(.body.italic()).foregroundStyle(secondaryText)
        } else if message.decryptFailed {
            Label("Couldn't decrypt this message. It may have been sent before this device was linked.", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.subheadline.italic()).foregroundStyle(secondaryText)
        } else if let c = content {
            if message.viewOnce {
                ViewOnceView(message: message, mine: mine)
            } else {
                switch c.type {
                case .text:
                    if isJumbo { Text(c.text ?? "").font(.system(size: 56)) } else { RichText(content: c, mine: mine) }
                case .media:
                    AttachmentGrid(message: message, attachments: c.attachments ?? [], mine: mine)
                    if let t = c.text, !t.isEmpty { RichText(content: c, mine: mine) }
                case .voice:
                    if let a = c.attachments?.first { VoiceNotePlayer(attachment: a, mine: mine) }
                case .videoNote:
                    if let a = c.attachments?.first { VideoNoteView(attachment: a) }
                case .poll:
                    PollView(message: message, mine: mine)
                case .event:
                    EventCard(message: message, mine: mine)
                case .location, .liveLocation:
                    if let l = c.location { LocationCard(location: l, live: c.type == .liveLocation) }
                case .contact:
                    Label(c.text ?? "Contact", systemImage: "person.crop.square")
                default:
                    Text(c.text ?? ChatEngine.preview(c))
                }
                if let lp = c.linkPreviews?.first { LinkPreviewCard(preview: lp, mine: mine) }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if message.unverified && !mine {
                Image(systemName: "exclamationmark.shield").help("Sender's key couldn't be verified")
            }
            if message.isStarred { Image(systemName: "star.fill") }
            if message.expiresAt != nil { Image(systemName: "timer") }
            if message.editedAt != nil { Text("edited") }
            Text(message.sentAt.formatted(date: .omitted, time: .shortened))
            if mine { StatusTicks(status: engine.status(of: message), message: message) }
        }
        .font(.caption2)
        .foregroundStyle(bare ? Color.secondary : secondaryText)
        .padding(bare ? 4 : 0)
        .background { if bare { Capsule().fill(.regularMaterial) } }
    }

    var accessibilityText: String {
        let who = mine ? "You" : engine.name(message.senderUserID)
        let what = message.wasDeleted ? "deleted message" : content.map(ChatEngine.preview) ?? ""
        return "\(who), \(what), \(message.sentAt.formatted(date: .omitted, time: .shortened))"
    }
}

struct StatusTicks: View {
    let status: MessageStatus
    let message: StoredMessage
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        switch status {
        case .sending: Image(systemName: "clock")
        case .failed:
            Button { Task { await engine.retry(message) } } label: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                .buttonStyle(.plain)
        case .sent: Image(systemName: "checkmark")
        case .delivered: DoubleCheck()
        case .read: DoubleCheck().foregroundStyle(Brand.teal)
        case .received: EmptyView()
        }
    }
}

struct DoubleCheck: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark").offset(x: 4)
        }
        .padding(.trailing, 4)
    }
}

nonisolated struct BubbleShape: Shape {
    var mine: Bool
    var tail: Bool
    var style: BubbleStyle

    func path(in r: CGRect) -> Path {
        let radius: CGFloat = style == .minimal ? 12 : 19
        guard tail else { return Path(roundedRect: r, cornerRadius: radius, style: .continuous) }
        var p = Path()
        // Rounded rect with a soft tail at the bottom corner on the sender's side.
        let small: CGFloat = 5
        if mine {
            p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            p.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - small))
            p.addQuadCurve(to: CGPoint(x: r.maxX + 6, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - 12, y: r.maxY - 2), control: CGPoint(x: r.maxX - 4, y: r.maxY + 1))
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY - 0))
            p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            p.move(to: CGPoint(x: r.maxX - radius, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
            p.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - small))
            p.addQuadCurve(to: CGPoint(x: r.minX - 6, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX + 12, y: r.maxY - 2), control: CGPoint(x: r.minX + 4, y: r.maxY + 1))
            p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
            p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
            p.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        }
        p.closeSubpath()
        return p
    }
}

struct SystemMessageView: View {
    let message: StoredMessage
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        Text(message.system.map { SystemText.describe($0, name: engine.name) } ?? "")
            .font(.caption).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

struct ReplyQuote: View {
    let targetID: UUID
    let onBubble: Bool
    let mine: Bool
    @Environment(ChatEngine.self) private var engine
    @Environment(ChatSession.self) private var session

    var body: some View {
        let target = try? engine.context.fetch(FetchDescriptorFactory.message(targetID)).first
        Button { session.jump(to: targetID) } label: {
            HStack(spacing: 8) {
                Capsule().fill(mine ? Color.white : Color.identity(target?.senderUserID)).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.name(target?.senderUserID)).font(.caption.bold())
                        .foregroundStyle(mine ? Color.white : Color.identity(target?.senderUserID))
                    Text(target.map { $0.wasDeleted ? "Deleted message" : $0.content.map(ChatEngine.preview) ?? "" } ?? "Message not loaded")
                        .font(.caption).lineLimit(2).opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background((mine ? Color.white : Color.primary).opacity(0.1), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

enum FetchDescriptorFactory {
    static func message(_ id: UUID) -> FetchDescriptor<StoredMessage> {
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return d
    }
}

struct ReactionsBar: View {
    let message: StoredMessage
    let mine: Bool
    @Environment(ChatEngine.self) private var engine
    @State private var showWho = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { r in
                let reacted = r.userIDs.contains(engine.myID ?? UUID())
                Button {
                    Haptics.tap()
                    Task { await engine.react(r.emoji, to: message) }
                } label: {
                    HStack(spacing: 3) {
                        Text(r.emoji)
                        if r.userIDs.count > 1 { Text("\(r.userIDs.count)").font(.caption.bold()).monospacedDigit() }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(reacted ? AnyShapeStyle(Color.accentColor.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: .capsule)
                    .overlay(Capsule().stroke(reacted ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .onLongPressGesture { showWho = true }
            }
        }
        .padding(.top, -6)
        .padding(.horizontal, 6)
        .transition(.scale.combined(with: .opacity))
        .popover(isPresented: $showWho) {
            List(message.reactions) { r in
                Section(r.emoji) { ForEach(r.userIDs, id: \.self) { Text(engine.name($0)) } }
            }
            .frame(minWidth: 240, minHeight: 240)
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct ThreadButton: View {
    let message: StoredMessage
    @Environment(ChatSession.self) private var session
    var body: some View {
        Button { session.threadRoot = message } label: {
            Label("\(message.replyCount) \(message.replyCount == 1 ? "reply" : "replies")", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Text with markdown, links and mentions.
struct RichText: View {
    let content: MessageContent
    let mine: Bool

    var body: some View {
        Text(attributed)
            .font(.body)
            .tint(mine ? .white : .accentColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    var attributed: AttributedString {
        let raw = content.text ?? ""
        var s = (try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(raw)
        // Detect bare links.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let plain = String(s.characters)
            for m in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let r = Range(m.range, in: plain), let url = m.url,
                      let lower = AttributedString.Index(r.lowerBound, within: s), let upper = AttributedString.Index(r.upperBound, within: s) else { continue }
                s[lower..<upper].link = url
                s[lower..<upper].underlineStyle = .single
            }
        }
        // Mentions: @name tokens.
        let plain = String(s.characters)
        if let re = try? NSRegularExpression(pattern: "(?<![\\w])@[a-z0-9_.]{2,32}", options: .caseInsensitive) {
            for m in re.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let r = Range(m.range, in: plain), let lower = AttributedString.Index(r.lowerBound, within: s),
                      let upper = AttributedString.Index(r.upperBound, within: s) else { continue }
                s[lower..<upper].font = .body.weight(.semibold)
                if !mine { s[lower..<upper].foregroundColor = .accentColor }
            }
        }
        return s
    }
}

struct ViewOnceView: View {
    let message: StoredMessage
    let mine: Bool
    @Environment(ChatSession.self) private var session
    @Environment(ChatEngine.self) private var engine
    var body: some View {
        Button {
            guard !mine, !message.viewedOnce else { return }
            session.viewer = MediaViewerItem(message: message, index: 0)
        } label: {
            Label(message.viewedOnce || mine ? "Opened" : "View once photo", systemImage: message.viewedOnce || mine ? "circle.dashed" : "1.circle")
                .font(.body.weight(.medium))
        }
        .buttonStyle(.plain)
    }
}

struct LinkPreviewCard: View {
    let preview: MessageContent.LinkPreview
    let mine: Bool
    var body: some View {
        Link(destination: URL(string: preview.url) ?? URL(string: "about:blank")!) {
            VStack(alignment: .leading, spacing: 4) {
                if let d = preview.image, let img = UIImage(data: d) {
                    Image(uiImage: img).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: 140).clipped()
                        .clipShape(.rect(cornerRadius: 10))
                }
                if let t = preview.title { Text(t).font(.subheadline.bold()).lineLimit(2) }
                if let d = preview.description { Text(d).font(.caption).lineLimit(3).opacity(0.8) }
                Text(URL(string: preview.url)?.host() ?? preview.url).font(.caption2).opacity(0.6)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((mine ? Color.white : Color.primary).opacity(0.08), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
