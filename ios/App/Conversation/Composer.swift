import AsgardKit
import AVFoundation
import PhotosUI
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct Composer: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(ChatSession.self) private var session
    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var showPoll = false
    @State private var showEvent = false
    @State private var showLocation = false
    @State private var showSchedule = false
    @State private var scheduleDate = Date.now.addingTimeInterval(3600)
    @State private var recorder = VoiceRecorder()
    @State private var suggestions: [String] = []
    @State private var viewOnce = false
    @FocusState private var focused: Bool

    var conversation: Conversation? { engine.conversation(conversationID) }
    var canSendMedia: Bool { conversation?.me?.permissions.contains(.sendMedia) ?? true }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 6) {
            if let reply = session.replyTo { ContextBar(title: "Reply to \(engine.name(reply.senderUserID))", message: reply, icon: "arrowshape.turn.up.left") { session.replyTo = nil } }
            if let edit = session.editing { ContextBar(title: "Edit message", message: edit, icon: "pencil") { session.editing = nil; text = "" } }
            if !mentionMatches.isEmpty { MentionSuggestions(users: mentionMatches) { insertMention($0) } }
            if !suggestions.isEmpty && trimmed.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { text = s; suggestions = [] }.buttonStyle(.glass).font(.subheadline)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            if recorder.isRecording {
                RecordingBar(recorder: recorder) { cancel in
                    if cancel { recorder.cancel() } else { Task { await sendVoice() } }
                }
            } else {
                inputRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear { text = engine.storedConversation(conversationID)?.draft ?? "" }
        .onDisappear { engine.storedConversation(conversationID)?.draft = session.editing == nil ? text : "" }
        .onChange(of: session.editing) { _, m in
            if let m { text = m.content?.text ?? ""; focused = true }
        }
        .onChange(of: session.replyTo) { _, m in if m != nil { focused = true } }
        .onChange(of: text) { _, t in if !t.isEmpty { engine.setTyping(conversationID) } }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoItems = []
            Task { await sendPicked(picked) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await sendFiles(urls) } }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data, mime in Task { await sendCaptured(data, mime: mime) } }.ignoresSafeArea()
        }
        .sheet(isPresented: $showPoll) { PollComposer { poll in Task { await sendContent(pollContent(poll)) } } }
        .sheet(isPresented: $showEvent) { EventComposer { event in Task { var c = MessageContent(type: .event); c.event = event; await sendContent(c) } } }
        .sheet(isPresented: $showLocation) { LocationPicker { loc, live in Task { var c = MessageContent(type: live ? .liveLocation : .location); c.location = loc; await sendContent(c) } } }
        .sheet(isPresented: $showSchedule) {
            NavigationStack {
                Form {
                    DatePicker("Send at", selection: $scheduleDate, in: Date.now.addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                }
                .navigationTitle("Schedule message")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSchedule = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Schedule") { showSchedule = false; Task { await sendText(options: .init(sendAt: scheduleDate)) } }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    var inputRow: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                HStack(alignment: .bottom) {
                    TextField(session.editing != nil ? "Edit message" : "Message", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($focused)
                        .padding(.vertical, 10)
                        .padding(.leading, 14)
                        .submitLabel(.return)
                    if Intelligence.isAvailable && trimmed.isEmpty && session.editing == nil {
                        Button { Task { await suggest() } } label: { Image(systemName: "sparkles").foregroundStyle(Brand.aurora) }
                            .padding(.bottom, 10)
                            .accessibilityLabel("Suggest replies")
                    }
                    if !trimmed.isEmpty || session.editing != nil {
                        Menu {
                            Button { Task { await sendText(options: .init(silent: true)) } } label: { Label("Send without sound", systemImage: "bell.slash") }
                            Button { showSchedule = true } label: { Label("Schedule message", systemImage: "calendar.badge.clock") }
                        } label: {
                            Image(systemName: session.editing != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 32)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                        } primaryAction: {
                            Task { await sendText() }
                        }
                        .padding(.trailing, 4).padding(.bottom, 3)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                if trimmed.isEmpty && session.editing == nil {
                    MicButton(recorder: recorder) { Task { await sendVoice() } }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: trimmed.isEmpty)
        }
    }

    var attachMenu: some View {
        Menu {
            if canSendMedia {
                Button { showPhotos = true } label: { Label("Photos & videos", systemImage: "photo.on.rectangle") }
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                Toggle(isOn: $viewOnce) { Label("View once", systemImage: "1.circle") }
            }
            Button { showLocation = true } label: { Label("Location", systemImage: "location") }
            Button { showPoll = true } label: { Label("Poll", systemImage: "chart.bar.xaxis") }
            Button { showEvent = true } label: { Label("Event", systemImage: "calendar") }
        } label: {
            Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Attach")
    }

    // MARK: mentions

    var mentionQuery: String? {
        guard conversation?.kind != .dm, let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst()).lowercased()
    }

    var mentionMatches: [User] {
        guard let q = mentionQuery else { return [] }
        let all = (try? engine.context.fetch(FetchDescriptor<StoredUser>()))?.compactMap(\.user) ?? []
        return Array(all.filter { $0.id != engine.myID && (q.isEmpty || $0.username.hasPrefix(q) || $0.displayName.lowercased().hasPrefix(q)) }.prefix(5))
    }

    func insertMention(_ u: User) {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        parts[parts.count - 1] = "@" + u.username + " "
        text = parts.joined(separator: " ")
    }

    // MARK: sending

    func sendText(options: ChatEngine.SendOptions = .init()) async {
        let body = trimmed
        if let editing = session.editing {
            session.editing = nil
            text = ""
            if !body.isEmpty && body != editing.content?.text { await engine.edit(editing, text: body) }
            return
        }
        guard !body.isEmpty else { return }
        text = ""
        suggestions = []
        Haptics.send()
        var opts = options
        opts.replyTo = session.replyTo?.id
        session.replyTo = nil
        var content = MessageContent.text(body)
        content.entities = mentionEntities(body)
        content.linkPreviews = await LinkPreviews.make(for: body)
        engine.setTyping(conversationID, state: "stopped")
        await engine.send(content, to: conversationID, options: opts)
    }

    func mentionEntities(_ body: String) -> [MessageContent.Entity]? {
        let users = (try? engine.context.fetch(FetchDescriptor<StoredUser>())) ?? []
        var out: [MessageContent.Entity] = []
        for u in users {
            let token = "@" + u.username
            var search = body.startIndex..<body.endIndex
            while let r = body.range(of: token, options: .caseInsensitive, range: search) {
                out.append(.init(kind: "mention", userID: u.id, range: [body.distance(from: body.startIndex, to: r.lowerBound), token.count]))
                search = r.upperBound..<body.endIndex
            }
        }
        if body.contains("@all") { out.append(.init(kind: "mention_all", range: [0, 0])) }
        return out.isEmpty ? nil : out
    }

    func sendContent(_ c: MessageContent) async {
        await engine.send(c, to: conversationID, options: .init(replyTo: session.replyTo?.id))
        session.replyTo = nil
    }

    func pollContent(_ poll: MessageContent.Poll) -> MessageContent {
        var c = MessageContent(type: .poll)
        c.poll = poll
        return c
    }

    func sendPicked(_ items: [PhotosPickerItem]) async {
        engine.setTyping(conversationID, state: "uploading")
        var files: [ChatEngine.OutgoingFile] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let movie = try? await item.loadTransferable(type: MovieFile.self) {
                if let f = await MediaPrep.video(at: movie.url) { files.append(f) }
            } else if let data = try? await item.loadTransferable(type: Data.self), let f = MediaPrep.image(data) {
                files.append(f)
            }
        }
        guard !files.isEmpty else { return }
        let caption = trimmed.isEmpty ? nil : trimmed
        text = ""
        await engine.sendFiles(files, caption: caption, to: conversationID, options: .init(replyTo: session.replyTo?.id, viewOnce: viewOnce))
        session.replyTo = nil
        viewOnce = false
    }

    func sendCaptured(_ data: Data, mime: String) async {
        let file: ChatEngine.OutgoingFile?
        if mime.hasPrefix("video") {
            let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
            try? data.write(to: url)
            file = await MediaPrep.video(at: url)
        } else {
            file = MediaPrep.image(data)
        }
        if let file { await engine.sendFiles([file], to: conversationID, options: .init(viewOnce: viewOnce)) }
    }

    func sendFiles(_ urls: [URL]) async {
        var files: [ChatEngine.OutgoingFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            files.append(.init(data: data, mime: mime, name: url.lastPathComponent))
        }
        if !files.isEmpty { await engine.sendFiles(files, to: conversationID) }
    }

    func sendVoice() async {
        guard let rec = recorder.finish() else { return }
        engine.setTyping(conversationID, state: "stopped")
        Haptics.send()
        await engine.sendFiles([.init(data: rec.data, mime: "audio/mp4", name: "Voice message.m4a", durationMS: rec.durationMS, waveform: rec.waveform)],
                               type: .voice, to: conversationID, options: .init(replyTo: session.replyTo?.id))
        session.replyTo = nil
    }

    func suggest() async {
        let conv = conversationID
        var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == conv }, sortBy: [SortDescriptor(\.sortKey, order: .reverse)])
        d.fetchLimit = 12
        let lines = ((try? engine.context.fetch(d)) ?? []).reversed().compactMap { m -> String? in
            m.content?.text.map { "\(m.senderUserID == engine.myID ? "Me" : engine.name(m.senderUserID)): \($0)" }
        }
        suggestions = await Intelligence.replies(lines: lines)
    }
}

struct ContextBar: View {
    let title: String
    let message: StoredMessage
    let icon: String
    var onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold()).foregroundStyle(Color.accentColor)
                Text(message.content.map(ChatEngine.preview) ?? "").font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct MentionSuggestions: View {
    let users: [User]
    var pick: (User) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(users) { u in
                Button { pick(u) } label: { UserRow(user: u).padding(.horizontal, 12).padding(.vertical, 6) }.buttonStyle(.plain)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}
