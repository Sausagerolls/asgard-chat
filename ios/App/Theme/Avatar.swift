import AsgardKit
import SwiftUI

/// Loads unencrypted avatar images with the session token.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()
    private let cache = NSCache<NSUUID, PlatformImage>()
    private var inFlight: [UUID: Task<PlatformImage?, Never>] = [:]

    func cached(_ id: UUID) -> PlatformImage? { cache.object(forKey: id as NSUUID) }

    func load(_ id: UUID, api: APIClient?) async -> PlatformImage? {
        if let img = cached(id) { return img }
        if let t = inFlight[id] { return await t.value }
        guard let api else { return nil }
        let task = Task<PlatformImage?, Never> {
            let file = AppGroup.mediaCacheURL.appending(path: "avatar-" + id.lower)
            if let d = try? Data(contentsOf: file), let img = PlatformImage(data: d) { return img }
            guard let d = try? await api.download(id), let img = PlatformImage(data: d) else { return nil }
            try? d.write(to: file)
            return img
        }
        inFlight[id] = task
        let img = await task.value
        inFlight[id] = nil
        if let img { cache.setObject(img, forKey: id as NSUUID) }
        return img
    }
}

struct AvatarView: View {
    var id: UUID?
    var name: String
    var mediaID: UUID?
    var size: CGFloat = 44
    var kind: ConversationKind? = nil
    var online = false

    @Environment(ChatEngine.self) private var engine
    @State private var image: PlatformImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(width: size, height: size)
                .clipShape(shape)
            if online {
                Circle().fill(Brand.teal)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(Color.platformBackground, lineWidth: size * 0.05))
                    .offset(x: -size * 0.02, y: -size * 0.02)
            }
        }
        .task(id: mediaID) {
            guard let mediaID else { image = nil; return }
            image = AvatarLoader.shared.cached(mediaID)
            if image == nil { image = await AvatarLoader.shared.load(mediaID, api: engine.api) }
        }
        .accessibilityHidden(true)
    }

    private var shape: AnyInsettableShape {
        kind == .community ? AnyInsettableShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)) : AnyInsettableShape(Circle())
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(platformImage: image).resizable().scaledToFill()
        } else if kind == .saved {
            ZStack {
                Brand.aurora
                Image(systemName: "bookmark.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            }
        } else {
            let c = Color.identity(id)
            ZStack {
                LinearGradient(colors: [c.mix(with: .white, by: 0.15), c.mix(with: .black, by: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if kind == .channel {
                    Image(systemName: "megaphone.fill").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                } else if kind == .community {
                    Image(systemName: "person.3.fill").font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

nonisolated struct AnyInsettableShape: InsettableShape, @unchecked Sendable {
    private let base: any InsettableShape
    init(_ s: some InsettableShape) { base = s }
    func path(in rect: CGRect) -> Path { base.path(in: rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { AnyInsettableShape(base.inset(by: amount)) }
    nonisolated var layoutDirectionBehavior: LayoutDirectionBehavior { .fixed }
}

extension StoredConversation {
    /// Avatar inputs for a conversation row.
    @MainActor func avatar(engine: ChatEngine, size: CGFloat) -> AvatarView {
        let c = conversation
        if kind == .dm, let peer = c?.peer {
            return AvatarView(id: peer.id, name: peer.displayName, mediaID: peer.avatarMediaID, size: size, online: engine.presence[peer.id]?.online ?? peer.online)
        }
        return AvatarView(id: id, name: title, mediaID: c?.avatarMediaID, size: size, kind: kind)
    }
}
