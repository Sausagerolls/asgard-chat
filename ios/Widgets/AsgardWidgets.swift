import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AsgardWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentChatsWidget()
        UnreadWidget()
        CallLiveActivity()
        NewMessageControl()
    }
}

struct ChatsEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

struct ChatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChatsEntry { ChatsEntry(date: .now, snapshot: .load()) }
    func getSnapshot(in context: Context, completion: @escaping (ChatsEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ChatsEntry>) -> Void) {
        completion(Timeline(entries: [ChatsEntry(date: .now, snapshot: .load())], policy: .after(.now.addingTimeInterval(1800))))
    }
}

enum WidgetBrand {
    static let violet = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let teal = Color(red: 0.176, green: 0.831, blue: 0.749)
    static let gold = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let night = Color(red: 0.031, green: 0.043, blue: 0.122)
    static let aurora = LinearGradient(colors: [violet, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Initials: View {
    let chat: WidgetSnapshot.Chat
    var size: CGFloat
    var body: some View {
        let colors: [Color] = [WidgetBrand.violet, WidgetBrand.teal, WidgetBrand.gold, .pink, .orange, .indigo]
        Circle().fill(colors[abs(chat.id.hashValue) % colors.count].gradient)
            .frame(width: size, height: size)
            .overlay(Text(String(chat.title.prefix(1))).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .overlay(alignment: .topTrailing) {
                if chat.unread > 0 {
                    Text("\(chat.unread)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(3).background(.red, in: .capsule)
                }
            }
    }
}

struct RecentChatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentChats", provider: ChatsProvider()) { entry in
            RecentChatsView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [WidgetBrand.night, Color(red: 0.08, green: 0.09, blue: 0.22)], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Recent chats")
        .description("Jump straight into your latest conversations.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentChatsView: View {
    let entry: ChatsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image("BrandMark").resizable().frame(width: 22, height: 22)
                    Spacer()
                    Text("\(entry.snapshot.unread)").font(.title2.bold()).foregroundStyle(.white)
                }
                Spacer()
                LazyVGrid(columns: [GridItem(), GridItem()], spacing: 8) {
                    ForEach(entry.snapshot.chats.prefix(4)) { c in
                        Link(destination: URL(string: "asgard://chat/\(c.id.uuidString)")!) { Initials(chat: c, size: 44) }
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image("BrandMark").resizable().frame(width: 18, height: 18)
                    Text("Asgard").font(.headline).foregroundStyle(.white)
                    Spacer()
                    if entry.snapshot.unread > 0 { Text("\(entry.snapshot.unread) unread").font(.caption.bold()).foregroundStyle(WidgetBrand.teal) }
                }
                ForEach(entry.snapshot.chats.prefix(family == .systemLarge ? 6 : 2)) { c in
                    Link(destination: URL(string: "asgard://chat/\(c.id.uuidString)")!) {
                        HStack(spacing: 10) {
                            Initials(chat: c, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.subheadline.bold()).foregroundStyle(.white)
                                Text(c.preview).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                            Spacer()
                            Text(c.date, style: .time).font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct UnreadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Unread", provider: ChatsProvider()) { entry in
            UnreadView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Unread messages")
        .description("Your unread count on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct UnreadView: View {
    let entry: ChatsEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.caption)
                    Text("\(entry.snapshot.unread)").font(.title3.bold())
                }
            }
        case .accessoryInline:
            Label("\(entry.snapshot.unread) unread", systemImage: "bubble.left.fill")
        default:
            VStack(alignment: .leading) {
                Label("Asgard · \(entry.snapshot.unread) unread", systemImage: "bubble.left.and.bubble.right.fill").font(.headline)
                if let c = entry.snapshot.chats.first(where: { $0.unread > 0 }) { Text("\(c.title): \(c.preview)").font(.caption).lineLimit(2) }
            }
        }
    }
}

struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.video ? "video.fill" : "phone.fill").font(.title2).foregroundStyle(WidgetBrand.teal)
                VStack(alignment: .leading) {
                    Text(context.attributes.title).font(.headline)
                    Text(context.state.participants > 2 ? "\(context.state.participants) people · Encrypted" : "End-to-end encrypted").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let t = context.state.connectedAt { Text(t, style: .timer).font(.title3.monospacedDigit()).frame(width: 70) } else { Text("Calling…") }
                if context.state.muted { Image(systemName: "mic.slash.fill").foregroundStyle(.red) }
            }
            .padding()
            .activityBackgroundTint(WidgetBrand.night.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: context.state.video ? "video.fill" : "phone.fill").font(.headline).foregroundStyle(WidgetBrand.teal)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let t = context.state.connectedAt { Text(t, style: .timer).monospacedDigit().frame(width: 60) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(context.state.muted ? "Muted" : "Mic on", systemImage: context.state.muted ? "mic.slash.fill" : "mic.fill")
                        Spacer()
                        Label("Encrypted", systemImage: "lock.fill")
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: context.state.video ? "video.fill" : "phone.fill").foregroundStyle(WidgetBrand.teal)
            } compactTrailing: {
                if let t = context.state.connectedAt { Text(t, style: .timer).monospacedDigit().frame(width: 44) } else { Image(systemName: "ellipsis") }
            } minimal: {
                Image(systemName: "phone.fill").foregroundStyle(WidgetBrand.teal)
            }
            .keylineTint(WidgetBrand.violet)
        }
    }
}

struct NewMessageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.giantmushroom.asgardchat.newmessage") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "asgard://compose")!)) {
                Label("New message", systemImage: "square.and.pencil")
            }
        }
        .displayName("Asgard message")
        .description("Start a new Asgard chat.")
    }
}
