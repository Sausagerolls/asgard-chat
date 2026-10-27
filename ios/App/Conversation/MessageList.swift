import AsgardKit
import SwiftData
import SwiftUI

enum Grouping { case single, first, middle, last
    var showsName: Bool { self == .single || self == .first }
    var showsTail: Bool { self == .single || self == .last }
}

struct MessageList: View {
    let conversationID: UUID
    let kind: ConversationKind
    @Environment(ChatEngine.self) private var engine
    @Environment(ChatSession.self) private var session
    @Query private var messages: [StoredMessage]
    @State private var atBottom = true
    @State private var firstUnreadSeq: Int64?
    @State private var loadingOlder = false

    init(conversationID: UUID, kind: ConversationKind) {
        self.conversationID = conversationID
        self.kind = kind
        _messages = Query(filter: #Predicate<StoredMessage> { $0.conversationID == conversationID && $0.threadRootID == nil },
                          sort: \StoredMessage.sortKey)
    }

    enum Row: Identifiable {
        case day(Date), unread, message(StoredMessage, Grouping)
        var id: String {
            switch self {
            case .day(let d): "day-\(d.timeIntervalSince1970)"
            case .unread: "unread"
            case .message(let m, _): m.clientID.uuidString
            }
        }
    }

    var rows: [Row] {
        var out: [Row] = []
        let cal = Calendar.current
        for (i, m) in messages.enumerated() {
            let prev = i > 0 ? messages[i - 1] : nil
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            if prev == nil || !cal.isDate(prev!.sentAt, inSameDayAs: m.sentAt) { out.append(.day(m.sentAt)) }
            if let f = firstUnreadSeq, m.seq == f { out.append(.unread) }
            let joinsPrev = prev.map { groups($0, m) } ?? false
            let joinsNext = next.map { groups(m, $0) } ?? false
            let g: Grouping = joinsPrev ? (joinsNext ? .middle : .last) : (joinsNext ? .first : .single)
            out.append(.message(m, g))
        }
        return out
    }

    func groups(_ a: StoredMessage, _ b: StoredMessage) -> Bool {
        !a.isSystem && !b.isSystem && a.senderUserID == b.senderUserID && b.sentAt.timeIntervalSince(a.sentAt) < 180
            && Calendar.current.isDate(a.sentAt, inSameDayAs: b.sentAt)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 1)
                        .onAppear { Task { await loadOlder() } }
                    if loadingOlder { ProgressView().padding() }
                    ForEach(rows) { row in
                        switch row {
                        case .day(let d):
                            Text(d.daySeparator).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 5)
                                .glassEffect(.regular, in: .capsule).padding(.vertical, 8)
                        case .unread:
                            Text("Unread messages").font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(.ultraThinMaterial).padding(.vertical, 6)
                        case .message(let m, let g):
                            MessageRow(message: m, grouping: g, isGroup: kind != .dm && kind != .saved, isChannel: kind == .channel)
                                .id(m.id)
                                .padding(.top, g == .first || g == .single ? 6 : 0)
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 120
            } action: { _, bottom in atBottom = bottom }
            .onChange(of: messages.count) { old, new in
                guard new > old, let last = messages.last else { return }
                if atBottom || last.senderUserID == engine.myID {
                    withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if engine.activeConversation == conversationID { engine.markRead(conversationID) }
            }
            .onChange(of: session.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.smooth) { proxy.scrollTo(target, anchor: .center) }
                session.scrollTarget = nil
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .overlay(alignment: .topLeading) {
                        let unread = engine.storedConversation(conversationID)?.unread ?? 0
                        if unread > 0 {
                            Text("\(unread)").font(.caption2.bold()).foregroundStyle(.white).padding(4).background(Color.accentColor, in: .capsule).offset(x: -4, y: -6)
                        }
                    }
                    .padding(16)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
        }
        .onAppear {
            if let sc = engine.storedConversation(conversationID), sc.unread > 0 {
                let unread = sc.unread
                let theirs = messages.filter { $0.senderUserID != engine.myID && !$0.isSystem }
                if theirs.count >= unread { firstUnreadSeq = theirs[theirs.count - unread].seq }
            }
        }
    }

    func loadOlder() async {
        guard !loadingOlder, messages.count >= 30 else { return }
        loadingOlder = true
        await engine.loadOlder(conversationID)
        loadingOlder = false
    }
}

extension Date {
    var daySeparator: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDate(self, equalTo: .now, toGranularity: .year) { return formatted(.dateTime.weekday(.wide).day().month(.wide)) }
        return formatted(date: .long, time: .omitted)
    }
}
