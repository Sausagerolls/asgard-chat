import AsgardKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet: pick a chat, add a note, send encrypted.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let container = (try? LocalStore.container()) ?? (try! LocalStore.container(inMemory: true))
        let engine = ChatEngine(container: container)
        let root = ShareView(items: items, engine: engine) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "Asgard", code: 0))
        }
        .environment(engine)
        .modelContainer(container)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    let items: [NSExtensionItem]
    let engine: ChatEngine
    var done: () -> Void
    var cancel: () -> Void
    @Query(sort: [SortDescriptor(\StoredConversation.sortDate, order: .reverse)]) private var conversations: [StoredConversation]
    @State private var selected: Set<UUID> = []
    @State private var note = ""
    @State private var sending = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section { TextField("Add a message", text: $note, axis: .vertical) }
                Section("Send to") {
                    ForEach(conversations.filter { $0.kind != .community && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { c in
                        Button { if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) } } label: {
                            HStack {
                                Text(c.title).font(.headline)
                                Spacer()
                                Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $search)
            .overlay { if engine.phase == .signedOut { ContentUnavailableView("Sign in to Asgard first", systemImage: "person.crop.circle.badge.exclamationmark") } }
            .navigationTitle("Asgard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else { Button("Send") { Task { await send() } }.disabled(selected.isEmpty) }
                }
            }
            .task { await engine.start() }
        }
    }

    func send() async {
        sending = true
        var texts: [String] = []
        var files: [ChatEngine.OutgoingFile] = []
        for item in items {
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                    texts.append(url.absoluteString)
                } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), let d = await load(p, .image) {
                    files.append(.init(data: d, mime: "image/jpeg", name: "Photo.jpg"))
                } else if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier), let d = await load(p, .movie) {
                    files.append(.init(data: d, mime: "video/mp4", name: "Video.mp4"))
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(t)
                } else if let d = await load(p, .data) {
                    files.append(.init(data: d, mime: "application/octet-stream", name: p.suggestedName ?? "File"))
                }
            }
        }
        let text = ([note] + texts).filter { !$0.isEmpty }.joined(separator: "\n")
        for conv in selected {
            if !files.isEmpty { await engine.sendFiles(files, caption: text.isEmpty ? nil : text, to: conv) }
            else if !text.isEmpty { await engine.send(.text(text), to: conv) }
        }
        done()
    }

    func load(_ p: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            _ = p.loadDataRepresentation(for: type) { d, _ in cont.resume(returning: d) }
        }
    }
}
