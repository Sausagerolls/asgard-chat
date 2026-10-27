import AsgardKit
import AVKit
import LinkPresentation
import Photos
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentGrid: View {
    let message: StoredMessage
    let attachments: [MessageContent.Attachment]
    let mine: Bool
    @Environment(ChatSession.self) private var session

    var visual: [MessageContent.Attachment] { attachments.filter { $0.isImage || $0.isVideo } }
    var files: [MessageContent.Attachment] { attachments.filter { !$0.isImage && !$0.isVideo } }

    var body: some View {
        VStack(spacing: 4) {
            if !visual.isEmpty {
                let cols = visual.count == 1 ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: cols), spacing: 3) {
                    ForEach(Array(visual.prefix(4).enumerated()), id: \.offset) { i, a in
                        AttachmentThumb(attachment: a, single: visual.count == 1)
                            .overlay {
                                if i == 3 && visual.count > 4 {
                                    ZStack { Color.black.opacity(0.45); Text("+\(visual.count - 4)").font(.title.bold()).foregroundStyle(.white) }
                                }
                            }
                            .onTapGesture { session.viewer = MediaViewerItem(message: message, index: i) }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))
                .padding(.horizontal, -6)
                .padding(.top, -2)
            }
            ForEach(Array(files.enumerated()), id: \.offset) { _, f in FileRow(attachment: f, mine: mine) }
        }
    }
}

struct AttachmentThumb: View {
    let attachment: MessageContent.Attachment
    var single = false
    @Environment(ChatEngine.self) private var engine
    @State private var image: UIImage?
    @State private var failed = false

    var aspect: CGFloat {
        guard let w = attachment.width, let h = attachment.height, w > 0, h > 0 else { return 1 }
        return max(0.6, min(1.8, CGFloat(w) / CGFloat(h)))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let t = attachment.thumbnail, let thumb = UIImage(data: t) {
                Image(uiImage: thumb).resizable().scaledToFill().blur(radius: 8)
            } else {
                Rectangle().fill(.quaternary)
            }
            if image == nil && !failed { ProgressView().tint(.white) }
            if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.white) }
            if attachment.isVideo {
                Image(systemName: "play.circle.fill").font(.system(size: 44)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.4))
                if let d = attachment.durationMS {
                    Text(Duration.milliseconds(d).formatted(.time(pattern: .minuteSecond))).font(.caption2.bold()).foregroundStyle(.white)
                        .padding(4).background(.black.opacity(0.5), in: .capsule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(single ? aspect : 1, contentMode: .fill)
        .frame(maxHeight: single ? 360 : 160)
        .clipped()
        .task(id: attachment.mediaID) { await load() }
    }

    func load() async {
        if attachment.isVideo {
            if let t = attachment.thumbnail { image = UIImage(data: t) }
            return
        }
        do {
            let data = try await engine.attachmentData(attachment)
            image = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 900, height: 900)) }.value
        } catch {
            failed = true
        }
    }
}

struct FileRow: View {
    let attachment: MessageContent.Attachment
    let mine: Bool
    @Environment(ChatEngine.self) private var engine
    @State private var previewURL: URL?
    @State private var loading = false

    var body: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill((mine ? Color.white : Color.accentColor).opacity(0.2)).frame(width: 42, height: 48)
                    if loading { ProgressView() } else { Image(systemName: icon).font(.title3) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name ?? "File").font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption).opacity(0.7)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .quickLookPreview($previewURL)
    }

    var icon: String {
        let t = UTType(mimeType: attachment.mime)
        if t?.conforms(to: .pdf) == true { return "doc.richtext" }
        if t?.conforms(to: .audio) == true { return "waveform" }
        if t?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc"
    }

    func open() async {
        loading = true
        defer { loading = false }
        guard let data = try? await engine.attachmentData(attachment) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: attachment.name ?? attachment.mediaID.uuidString)
        try? data.write(to: url)
        previewURL = url
    }
}

struct VideoNoteView: View {
    let attachment: MessageContent.Attachment
    @Environment(ChatEngine.self) private var engine
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player).disabled(true)
            } else if let t = attachment.thumbnail, let img = UIImage(data: t) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Brand.bifrost, lineWidth: 3))
        .onTapGesture { Task { await play() } }
    }

    func play() async {
        if let player { player.timeControlStatus == .playing ? player.pause() : player.play(); return }
        guard let data = try? await engine.attachmentData(attachment) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: attachment.mediaID.uuidString + ".mp4")
        try? data.write(to: url)
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }
}

/// Full-screen swipeable viewer for a message's photos and videos.
struct MediaViewer: View {
    let message: StoredMessage
    let startIndex: Int
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var dragY: CGFloat = 0

    var items: [MessageContent.Attachment] { (message.content?.attachments ?? []).filter { $0.isImage || $0.isVideo } }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - Double(min(abs(dragY) / 400, 0.7))).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, a in
                    ViewerPage(attachment: a).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
            .offset(y: dragY)
            .gesture(DragGesture().onChanged { dragY = $0.translation.height }.onEnded { v in
                if abs(v.translation.height) > 140 { dismiss() } else { withAnimation(.spring) { dragY = 0 } }
            })
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40) }
                    .glassEffect(.regular.interactive(), in: .circle)
                Spacer()
                VStack {
                    Text(engine.name(message.senderUserID)).font(.headline)
                    Text(message.sentAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                .foregroundStyle(.white)
                Spacer()
                if !message.viewOnce, index < items.count {
                    Menu {
                        Button { Task { await MediaSaver.save(items[index], engine: engine) } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        ShareAttachmentButton(attachment: items[index])
                    } label: { Image(systemName: "ellipsis").font(.headline).frame(width: 40, height: 40) }
                        .glassEffect(.regular.interactive(), in: .circle)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .padding()
        }
        .onAppear { index = startIndex }
        .onDisappear { if message.viewOnce && message.senderUserID != engine.myID { engine.markViewedOnce(message) } }
        .statusBarHidden()
    }
}

struct ViewerPage: View {
    let attachment: MessageContent.Attachment
    @Environment(ChatEngine.self) private var engine
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit().scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation(.spring) { scale = 1 } })
                    .onTapGesture(count: 2) { withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5 } }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            guard let data = try? await engine.attachmentData(attachment) else { return }
            if attachment.isVideo {
                let url = FileManager.default.temporaryDirectory.appending(path: attachment.mediaID.uuidString + ".mp4")
                try? data.write(to: url)
                player = AVPlayer(url: url)
            } else {
                image = UIImage(data: data)
            }
        }
    }
}

struct ShareAttachmentButton: View {
    let attachment: MessageContent.Attachment
    @Environment(ChatEngine.self) private var engine
    @State private var url: URL?
    var body: some View {
        if let url { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
        else {
            Button { Task {
                guard let d = try? await engine.attachmentData(attachment) else { return }
                let u = FileManager.default.temporaryDirectory.appending(path: attachment.name ?? (attachment.mediaID.uuidString + (attachment.isVideo ? ".mp4" : ".jpg")))
                try? d.write(to: u)
                url = u
            } } label: { Label("Prepare to share", systemImage: "square.and.arrow.up") }
        }
    }
}

enum MediaSaver {
    @MainActor static func save(_ a: MessageContent.Attachment, engine: ChatEngine) async {
        guard let data = try? await engine.attachmentData(a) else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { engine.banner = "Allow photo access in Settings to save."; return }
        let url = FileManager.default.temporaryDirectory.appending(path: a.mediaID.uuidString + (a.isVideo ? ".mp4" : ".jpg"))
        try? data.write(to: url)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if a.isVideo { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
            }
            engine.banner = "Saved to Photos"
            Haptics.success()
        } catch {
            engine.banner = "Couldn't save."
        }
    }
}

/// Image/video preparation before encryption.
enum MediaPrep {
    static func image(_ data: Data) -> ChatEngine.OutgoingFile? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 2560
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = scale < 1 ? (img.preparingThumbnail(of: target) ?? img) : img
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
        return .init(data: jpeg, mime: "image/jpeg", name: "Photo.jpg", width: Int(resized.size.width), height: Int(resized.size.height),
                     thumbnail: tinyThumbnail(resized))
    }

    static func video(at url: URL) async -> ChatEngine.OutgoingFile? {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { Int($0.seconds * 1000) }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        var thumb: Data?
        var size: CGSize?
        if let (cg, _) = try? await gen.image(at: .zero) {
            let ui = UIImage(cgImage: cg)
            thumb = tinyThumbnail(ui, maxBytes: 12_000)
            size = ui.size
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return .init(data: data, mime: "video/mp4", name: url.lastPathComponent, width: size.map { Int($0.width) }, height: size.map { Int($0.height) },
                     durationMS: duration, thumbnail: thumb)
    }

    static func tinyThumbnail(_ img: UIImage, maxBytes: Int = 8000) -> Data? {
        var side: CGFloat = 96
        while side >= 24 {
            if let t = img.preparingThumbnail(of: CGSize(width: side, height: side * img.size.height / max(img.size.width, 1))),
               let d = t.jpegData(compressionQuality: 0.5), d.count <= maxBytes { return d }
            side *= 0.7
        }
        return nil
    }
}

enum LinkPreviews {
    /// Builds a preview on this device so the server never learns the URL.
    static func make(for text: String) async -> [MessageContent.LinkPreview]? {
        guard UserDefaults.standard.object(forKey: "linkPreviews") as? Bool ?? true,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let url = match.url,
              url.scheme?.hasPrefix("http") == true else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 4
        guard let meta = try? await provider.startFetchingMetadata(for: url) else { return [.init(url: url.absoluteString)] }
        var image: Data?
        if let ip = meta.imageProvider, let img = try? await ip.loadImage() {
            image = MediaPrep.tinyThumbnail(img, maxBytes: 16_000)
        }
        return [.init(url: url.absoluteString, title: meta.title, description: nil, image: image)]
    }
}

extension NSItemProvider {
    func loadImage() async throws -> UIImage? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadObject(ofClass: UIImage.self) { obj, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: obj as? UIImage) }
            }
        }
    }
}

extension UIImage {
    func squareThumbnail(_ side: CGFloat) -> UIImage? {
        let s = min(size.width, size.height)
        let crop = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
        guard let cg = cgImage?.cropping(to: crop.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return self }
        return UIImage(cgImage: cg, scale: 1, orientation: imageOrientation).preparingThumbnail(of: CGSize(width: side, height: side))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        p.videoQuality = .typeHigh
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL, let d = try? Data(contentsOf: url) { parent.onCapture(d, "video/quicktime") }
            else if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.9) { parent.onCapture(d, "image/jpeg") }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
