import AppKit
import AsgardKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Desktop composer: Return sends, Shift-Return adds a line, paste or drop
/// files, ⌘L focuses it from anywhere.
struct MacComposer: View {
    let conversationID: UUID
    let canPost: Bool
    @Environment(ChatEngine.self) private var engine
    @Environment(MacChatState.self) private var state
    @Environment(MacNavigator.self) private var nav
    @State private var text = ""
    @State private var importing = false
    @State private var pending: [ChatEngine.OutgoingFile] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let r = state.replyTo ?? state.editing {
                HStack(spacing: 8) {
                    Image(systemName: state.editing != nil ? "pencil" : "arrowshape.turn.up.left").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.editing != nil ? "Editing" : "Replying to \(engine.name(r.senderUserID))").font(.caption.weight(.semibold))
                        Text(r.content.map(ChatEngine.preview) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { state.replyTo = nil; state.editing = nil; text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            if !pending.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, f in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if f.mime.hasPrefix("image/"), let img = NSImage(data: f.data) {
                                        Image(nsImage: img).resizable().scaledToFill()
                                    } else {
                                        VStack { Image(systemName: "doc.fill").font(.title); Text(f.name ?? "File").font(.caption2).lineLimit(1) }.padding(6)
                                    }
                                }
                                .frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 10))
                                Button { pending.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).padding(2)
                            }
                        }
                    }
                }
                .frame(height: 76)
            }
            if canPost {
                HStack(alignment: .bottom, spacing: 8) {
                    Button { importing = true } label: { Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 30, height: 30) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).help("Attach Files")
                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...10)
                        .focused($focused)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { text += "\n"; return .handled }
                            send()
                            return .handled
                        }
                        .onPasteCommand(of: [.image, .fileURL]) { providers in Task { await addPasted(providers) } }
                        .onChange(of: text) { _, t in
                            if !t.isEmpty { engine.setTyping(conversationID) }
                            engine.storedConversation(conversationID)?.draft = state.editing == nil ? t : ""
                        }
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white).frame(width: 30, height: 30)
                            .background(Color.accentColor.gradient, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty)
                    .help("Send (Return)")
                }
            } else {
                Text("Only admins can post in this channel. React, vote, or join the voice room.")
                    .font(.callout).foregroundStyle(.secondary).padding(10)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                let access = url.startAccessingSecurityScopedResource()
                if let f = MacFiles.outgoing(url) { pending.append(f) }
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
        .onAppear {
            text = engine.storedConversation(conversationID)?.draft ?? ""
            focused = true
        }
        .onChange(of: nav.composeFocus) { _, _ in focused = true }
        .onChange(of: state.editing) { _, m in if let m { text = m.content?.text ?? ""; focused = true } }
        .onChange(of: state.replyTo) { _, m in if m != nil { focused = true } }
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !pending.isEmpty else { return }
        if let editing = state.editing {
            Task { await engine.edit(editing, text: t) }
            state.editing = nil
        } else if !pending.isEmpty {
            let files = pending, reply = state.replyTo?.id
            Task { await engine.sendFiles(files, caption: t.isEmpty ? nil : t, to: conversationID, options: .init(replyTo: reply)) }
            pending = []
        } else {
            let reply = state.replyTo?.id
            Task { _ = await engine.send(.text(t), to: conversationID, options: .init(replyTo: reply)) }
        }
        state.replyTo = nil
        text = ""
        engine.storedConversation(conversationID)?.draft = ""
    }

    func addPasted(_ providers: [NSItemProvider]) async {
        for p in providers {
            if let d = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let url = URL(dataRepresentation: d, relativeTo: nil), let f = MacFiles.outgoing(url) {
                pending.append(f)
            } else if let d = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) as? Data, let f = MacFiles.outgoingImage(d) {
                pending.append(f)
            } else if let d = await MacFiles.loadData(p, .png), let f = MacFiles.outgoingImage(d) {
                pending.append(f)
            }
        }
    }
}

enum MacFiles {
    static func outgoing(_ url: URL) -> ChatEngine.OutgoingFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image), let f = outgoingImage(data, name: url.lastPathComponent) { return f }
        return .init(data: data, mime: type.preferredMIMEType ?? "application/octet-stream", name: url.lastPathComponent)
    }

    /// Re-encodes images as JPEG (except GIF/PNG with transparency kept as-is) and adds a thumbnail.
    static func outgoingImage(_ data: Data, name: String? = nil) -> ChatEngine.OutgoingFile? {
        guard let img = NSImage(data: data), let rep = img.representations.first else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let thumb = img.thumbnailJPEG(maxSide: 64)
        if name?.lowercased().hasSuffix(".gif") == true {
            return .init(data: data, mime: "image/gif", name: name, width: w, height: h, thumbnail: thumb)
        }
        guard let jpeg = img.jpegData(maxSide: 2560) else { return nil }
        return .init(data: jpeg, mime: "image/jpeg", name: name ?? "Image.jpg", width: w, height: h, thumbnail: thumb)
    }

    static func loadData(_ p: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { c in _ = p.loadDataRepresentation(for: type) { d, _ in c.resume(returning: d) } }
    }
}

extension NSImage {
    func jpegData(maxSide: CGFloat, quality: Double = 0.85) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    func thumbnailJPEG(maxSide: CGFloat) -> Data? { jpegData(maxSide: maxSide, quality: 0.6) }
}

/// Decrypts and shows an attachment: inline images, playable audio/video, saveable files.
struct MacAttachmentView: View {
    let message: StoredMessage
    let attachment: MessageContent.Attachment
    let mine: Bool
    @Environment(ChatEngine.self) private var engine
    @State private var data: Data?
    @State private var failed = false
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var isImage: Bool { attachment.mime.hasPrefix("image/") }
    var isAudio: Bool { attachment.mime.hasPrefix("audio/") }
    var isVideo: Bool { attachment.mime.hasPrefix("video/") }

    var body: some View {
        Group {
            if isImage {
                if let data, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 360)
                        .clipShape(.rect(cornerRadius: 12))
                        .onTapGesture(count: 2) { open() }
                        .contextMenu { Button("Open in Preview") { open() }; Button("Save…") { save() } }
                } else {
                    placeholder.frame(width: 240, height: 180)
                }
            } else if isAudio {
                HStack(spacing: 10) {
                    Button { toggleAudio() } label: { Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30)) }
                        .buttonStyle(.plain)
                    Waveform(data: attachment.waveform).frame(width: 160, height: 26)
                    Text(Duration.milliseconds(attachment.durationMS ?? 0).formatted(.time(pattern: .minuteSecond))).font(.caption.monospacedDigit())
                }
            } else {
                Button { if isVideo { open() } else { save() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isVideo ? "play.rectangle.fill" : "doc.fill").font(.title)
                        VStack(alignment: .leading) {
                            Text(attachment.name ?? (isVideo ? "Video" : "File")).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption).opacity(0.7)
                        }
                        if data == nil && !failed { ProgressView().controlSize(.small) }
                    }
                    .padding(8).background(.black.opacity(0.12), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .task { await load() }
    }

    var placeholder: some View {
        ZStack {
            Rectangle().fill(.secondary.opacity(0.2))
            if failed { Image(systemName: "exclamationmark.triangle") } else { ProgressView() }
        }
        .clipShape(.rect(cornerRadius: 12))
    }

    func load() async {
        if data != nil { return }
        do { data = try await engine.attachmentData(attachment) } catch { failed = true }
    }

    func tempFile() -> URL? {
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: attachment.name ?? (attachment.mediaID.lower + "." + (UTType(mimeType: attachment.mime)?.preferredFilenameExtension ?? "bin")))
        try? data.write(to: url)
        return url
    }

    func open() { if let url = tempFile() { NSWorkspace.shared.open(url) } }

    func save() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name ?? "Attachment"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    func toggleAudio() {
        if playing { player?.pause(); playing = false; return }
        if player == nil, let data { player = try? AVAudioPlayer(data: data) }
        player?.play()
        playing = player != nil
        if let d = player?.duration {
            Task { try? await Task.sleep(for: .seconds(d)); playing = false }
        }
    }
}

struct Waveform: View {
    let data: Data?
    var body: some View {
        let samples = data.map { Array($0) } ?? Array(repeating: 40, count: 40)
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(samples.prefix(48).enumerated()), id: \.offset) { _, v in
                Capsule().frame(width: 2, height: max(3, CGFloat(v) / 255 * 26))
            }
        }
        .opacity(0.8)
    }
}
