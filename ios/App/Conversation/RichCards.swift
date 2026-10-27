import AsgardKit
import EventKit
import EventKitUI
import MapKit
import SwiftData
import SwiftUI

struct PollView: View {
    let message: StoredMessage
    let mine: Bool
    @Environment(ChatEngine.self) private var engine

    var poll: MessageContent.Poll? { message.content?.poll }
    var votes: [String: [String]] { message.votes }
    var myVotes: [String] { votes[engine.myID?.lower ?? ""] ?? [] }
    var total: Int { votes.values.filter { !$0.isEmpty }.count }
    var closed: Bool { (poll?.closesAt ?? .distantFuture) < .now }

    var body: some View {
        if let poll {
            VStack(alignment: .leading, spacing: 10) {
                Label(poll.question, systemImage: "chart.bar.xaxis").font(.headline)
                Text(poll.anonymous ? "Anonymous poll" : poll.multiple ? "Select one or more" : "Select one").font(.caption).opacity(0.7)
                ForEach(poll.options) { o in
                    let count = votes.values.filter { $0.contains(o.id) }.count
                    let fraction = total > 0 ? Double(count) / Double(total) : 0
                    let chosen = myVotes.contains(o.id)
                    Button { Task { await vote(o.id) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                                Text(o.text)
                                Spacer()
                                if !myVotes.isEmpty || closed { Text("\(Int(fraction * 100))%").font(.caption.bold()).monospacedDigit() }
                            }
                            GeometryReader { g in
                                Capsule().fill((mine ? Color.white : Color.accentColor).opacity(0.25))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(mine ? Color.white : Color.accentColor)
                                            .frame(width: myVotes.isEmpty && !closed ? 0 : g.size.width * fraction)
                                    }
                            }
                            .frame(height: 6)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(closed)
                }
                Text("\(total) \(total == 1 ? "vote" : "votes")" + (closed ? " · Final results" : "")).font(.caption).opacity(0.7)
            }
            .frame(minWidth: 240)
            .animation(.smooth, value: votes)
        }
    }

    func vote(_ id: String) async {
        Haptics.tap()
        var next = myVotes
        if poll?.multiple == true {
            if let i = next.firstIndex(of: id) { next.remove(at: i) } else { next.append(id) }
        } else {
            next = next == [id] ? [] : [id]
        }
        await engine.vote(next, on: message)
    }
}

struct EventCard: View {
    let message: StoredMessage
    let mine: Bool
    @Environment(ChatEngine.self) private var engine
    @State private var addToCalendar = false

    var event: MessageContent.Event? { message.content?.event }
    var mine_: String? { message.rsvps[engine.myID?.lower ?? ""] }

    var body: some View {
        if let e = event {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Text(e.startsAt.formatted(.dateTime.month(.abbreviated))).font(.caption2.bold()).textCase(.uppercase).foregroundStyle(.red)
                        Text(e.startsAt.formatted(.dateTime.day())).font(.title2.bold())
                    }
                    .frame(width: 48, height: 52)
                    .background(.white.opacity(mine ? 0.9 : 0.15), in: .rect(cornerRadius: 10))
                    .foregroundStyle(mine ? Color.black : Color.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.headline)
                        Text(e.startsAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                        if let l = e.location, !l.isEmpty { Label(l, systemImage: "mappin.and.ellipse").font(.caption) }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(MessageContent.RSVP.Status.allCases, id: \.self) { s in
                        let count = message.rsvps.values.filter { $0 == s.rawValue }.count
                        Button { Task { await engine.rsvp(s, on: message) } } label: {
                            Text("\(s == .yes ? "Going" : s == .no ? "Can't go" : "Maybe")\(count > 0 ? " · \(count)" : "")")
                                .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(mine_ == s.rawValue ? AnyShapeStyle(mine ? Color.white.opacity(0.35) : Color.accentColor.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.1)), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button { addToCalendar = true } label: { Image(systemName: "calendar.badge.plus") }.buttonStyle(.plain)
                }
            }
            .frame(minWidth: 250)
            .sheet(isPresented: $addToCalendar) { CalendarEventEditor(event: e) }
        }
    }
}

struct CalendarEventEditor: UIViewControllerRepresentable {
    let event: MessageContent.Event
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let vc = EKEventEditViewController()
        vc.eventStore = store
        let e = EKEvent(eventStore: store)
        e.title = event.title
        e.startDate = event.startsAt
        e.endDate = event.endsAt ?? event.startsAt.addingTimeInterval(3600)
        e.location = event.location
        e.notes = event.notes
        vc.event = e
        vc.editViewDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true)
        }
    }
}

struct LocationCard: View {
    let location: MessageContent.Location
    let live: Bool
    var coordinate: CLLocationCoordinate2D { .init(latitude: location.lat, longitude: location.lon) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(.init(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)), interactionModes: []) {
                Marker(location.name ?? "Location", coordinate: coordinate).tint(live ? .red : .accentColor)
            }
            .frame(width: 250, height: 150)
            .clipShape(.rect(cornerRadius: 12))
            .onTapGesture {
                let item = MKMapItem(location: CLLocation(latitude: location.lat, longitude: location.lon), address: nil)
                item.name = location.name
                item.openInMaps()
            }
            if live, let until = location.liveUntil {
                Label(until > .now ? "Live until \(until.formatted(date: .omitted, time: .shortened))" : "Live location ended", systemImage: "location.fill")
                    .font(.caption)
            } else if let n = location.name {
                Text(n).font(.subheadline)
            }
        }
    }
}

struct LocationPicker: View {
    var onSend: (MessageContent.Location, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var manager = CLLocationManager()

    var body: some View {
        NavigationStack {
            Map(position: $position) { UserAnnotation() }
                .onMapCameraChange { center = $0.region.center }
                .overlay { Image(systemName: "mappin").font(.largeTitle).foregroundStyle(.red).offset(y: -16) }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        Button { send(live: false) } label: { Label("Send this location", systemImage: "location.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.glassProminent)
                        Button { send(live: true) } label: { Label("Share live location for 1 hour", systemImage: "location.circle").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                    }
                    .padding()
                }
                .navigationTitle("Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { manager.requestWhenInUseAuthorization() }
        }
    }

    func send(live: Bool) {
        guard let c = center ?? manager.location?.coordinate else { return }
        onSend(.init(lat: c.latitude, lon: c.longitude, accuracy: manager.location?.horizontalAccuracy, liveUntil: live ? .now.addingTimeInterval(3600) : nil), live)
        dismiss()
    }
}

struct PollComposer: View {
    var onSend: (MessageContent.Poll) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multiple = false
    @State private var anonymous = false

    var valid: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") { TextField("Ask something", text: $question, axis: .vertical) }
                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in
                        TextField("Option \(i + 1)", text: $options[i])
                    }
                    .onDelete { options.remove(atOffsets: $0) }
                    if options.count < 12 { Button("Add option") { options.append("") } }
                }
                Section {
                    Toggle("Allow multiple answers", isOn: $multiple)
                    Toggle("Anonymous voting", isOn: $anonymous)
                }
            }
            .navigationTitle("New poll")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let opts = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            .enumerated().map { MessageContent.Poll.Option(id: String(UnicodeScalar(97 + $0.offset)!), text: $0.element) }
                        onSend(.init(question: question, options: opts, multiple: multiple, anonymous: anonymous))
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }
}

struct EventComposer: View {
    var onSend: (MessageContent.Event) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
    @State private var end = Date.now.addingTimeInterval(7200)
    @State private var location = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Event name", text: $title)
                DatePicker("Starts", selection: $start)
                DatePicker("Ends", selection: $end, in: start...)
                TextField("Location", text: $location)
                TextField("Notes", text: $notes, axis: .vertical)
            }
            .navigationTitle("New event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(.init(title: title, startsAt: start, endsAt: end, location: location, notes: notes)); dismiss() }
                        .disabled(title.isEmpty)
                }
            }
        }
    }
}

struct EmojiPickerSheet: View {
    var onPick: (String) -> Void
    @State private var query = ""
    static let groups: [(String, String)] = [
        ("Smileys", "😀😃😄😁😆😅😂🤣🥲☺️😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🥸🤩🥳😏😒😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🤗🤔🫡🤭🤫🤥😶😐😑😬🙄😯😦😧😮😲🥱😴🤤😪😵🤐🥴🤢🤮🤧😷🤒🤕"),
        ("Gestures", "👍👎👊✊🤛🤜🤞✌️🤟🤘👌🤌🤏👈👉👆👇☝️✋🤚🖐🖖👋🤙💪🦾🙏🫶👏🙌👐🤲🤝"),
        ("Hearts", "❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝"),
        ("Norse", "⚡️🔨🛡️⚔️🪓🐺🦅🐦‍⬛🌈🌌❄️🔥🌊🌲🍯🍺🐐🐍🌳👁️🌙☀️⭐️✨🏔️⛵️"),
        ("Objects", "🎉🎊🎁🎂🍰☕️🍕🍔🍟🌮🍣🍿🎮🎧🎵🎸📷💡📌📎✏️📚💻📱⌚️🔒🔑🚀✈️🚗🏠"),
        ("Symbols", "✅❌⚠️❓❗️💯🔝🆗🆕🔴🟠🟡🟢🔵🟣⚫️⚪️➕➖➗✖️♾️"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.groups, id: \.0) { name, emojis in
                        Text(name).font(.headline).padding(.horizontal)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                            ForEach(Array(emojis).map(String.init), id: \.self) { e in
                                Button { onPick(e) } label: { Text(e).font(.system(size: 32)) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct MessageInfoSheet: View {
    let message: StoredMessage
    @Environment(ChatEngine.self) private var engine
    @State private var members: [Member] = []

    var body: some View {
        NavigationStack {
            List {
                Section { MessageBubble(message: message, grouping: .single, isGroup: false).frame(maxWidth: .infinity, alignment: .trailing).listRowBackground(Color.clear) }
                let read = members.filter { m in m.user.id != engine.myID && (engine.readMarks[message.conversationID]?[m.user.id] ?? m.readSeq) >= message.seq }
                let delivered = members.filter { m in m.user.id != engine.myID && !read.contains(m) && (engine.deliveredMarks[message.conversationID]?[m.user.id] ?? 0) >= message.seq }
                Section("Read by \(read.count)") { ForEach(read) { UserRow(user: $0.user) } }
                Section("Delivered to \(delivered.count)") { ForEach(delivered) { UserRow(user: $0.user) } }
                Section {
                    LabeledContent("Sent", value: message.sentAt.formatted(date: .abbreviated, time: .standard))
                    if let e = message.editedAt { LabeledContent("Edited", value: e.formatted(date: .abbreviated, time: .standard)) }
                    if let x = message.expiresAt { LabeledContent("Disappears", value: x.formatted(.relative(presentation: .named))) }
                    LabeledContent("Encryption", value: "End-to-end")
                }
            }
            .navigationTitle("Message info")
            .navigationBarTitleDisplayMode(.inline)
            .task { members = await engine.members(message.conversationID) }
        }
    }
}

struct ForwardSheet: View {
    let messages: [StoredMessage]
    var done: () -> Void
    @Environment(ChatEngine.self) private var engine
    @Query(sort: [SortDescriptor(\StoredConversation.sortDate, order: .reverse)]) private var conversations: [StoredConversation]
    @State private var selected: Set<UUID> = []
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { c in
                Button { if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) } } label: {
                    HStack {
                        c.avatar(engine: engine, size: 40)
                        Text(c.title).font(.headline)
                        Spacer()
                        Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(c.id) ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search)
            .navigationTitle("Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let targets = Array(selected)
                        Task { for m in messages { await engine.forward(m, to: targets) }; done() }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct ThreadView: View {
    let root: StoredMessage
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Query private var replies: [StoredMessage]
    @State private var text = ""

    init(root: StoredMessage) {
        self.root = root
        let rid = root.id
        _replies = Query(filter: #Predicate<StoredMessage> { $0.threadRootID == rid }, sort: \StoredMessage.sortKey)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 4) {
                    MessageBubble(message: root, grouping: .single, isGroup: true).frame(maxWidth: .infinity, alignment: root.senderUserID == engine.myID ? .trailing : .leading)
                    Divider().padding(.vertical, 8)
                    ForEach(replies) { r in
                        MessageBubble(message: r, grouping: .single, isGroup: true)
                            .frame(maxWidth: .infinity, alignment: r.senderUserID == engine.myID ? .trailing : .leading)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Reply in thread", text: $text, axis: .vertical).padding(12).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                    Button {
                        let t = text
                        text = ""
                        Task { _ = await engine.send(.text(t), to: root.conversationID, options: .init(threadRootID: root.id)) }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)) }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
