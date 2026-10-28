import AsgardKit
import SwiftUI

/// Everyone on the server, favourites first, with one-tap message and call buttons.
struct PeopleTab: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(CallManager.self) private var calls
    @Environment(Router.self) private var router
    @State private var people: [User] = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?

    private var filtered: [User] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return people.filter { q.isEmpty || $0.displayName.localizedCaseInsensitiveContains(q) || $0.username.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            let favs = engine.favoriteUserIDs
            List {
                let favourites = filtered.filter { favs.contains($0.id) }
                if !favourites.isEmpty {
                    Section("Favourites") { ForEach(favourites) { row($0, favourite: true) } }
                }
                let others = filtered.filter { !favs.contains($0.id) }
                if !others.isEmpty {
                    Section(favourites.isEmpty ? "" : "Everyone") { ForEach(others) { row($0, favourite: false) } }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AuroraBackground(intensity: 0.35))
            .overlay {
                if loading && people.isEmpty {
                    ProgressView()
                } else if filtered.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No one else here yet" : "No matches",
                                           systemImage: "person.2",
                                           description: Text(search.isEmpty ? "Invite people to your server from Server Admin." : ""))
                }
            }
            .navigationTitle("People")
            .searchable(text: $search, prompt: "Search people")
            .refreshable { await load() }
            .task { await load() }
            .alert("Couldn't start that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: { Text(error ?? "") }
        }
    }

    private func row(_ u: User, favourite: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(id: u.id, name: u.displayName, mediaID: u.avatarMediaID, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(u.displayName).font(.headline).lineLimit(1)
                Text(u.online ? "Online" : "@" + u.username)
                    .font(.subheadline).foregroundStyle(u.online ? .green : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                action("message.fill", "Message \(u.displayName)") { await message(u) }
                if engine.callsAvailable {
                    action("phone.fill", "Call \(u.displayName)") { await call(u, video: false) }
                    action("video.fill", "Video call \(u.displayName)") { await call(u, video: true) }
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            Button { Task { await engine.setFavorite(u.id, !favourite) } } label: {
                Label(favourite ? "Unfavourite" : "Favourite", systemImage: favourite ? "star.slash.fill" : "star.fill")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button { Task { await engine.setFavorite(u.id, !favourite) } } label: {
                Label(favourite ? "Remove from favourites" : "Add to favourites", systemImage: favourite ? "star.slash" : "star")
            }
        }
    }

    private func action(_ icon: String, _ label: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.18), in: .circle)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private func load() async {
        people = await engine.searchUsers("").filter { !$0.isBot }
        loading = false
    }

    private func message(_ u: User) async {
        do {
            let id = try await engine.openDM(with: u.id)
            router.selectedTab = .chats
            router.openConversation = id
        } catch { self.error = (error as? APIError)?.message ?? "Check your connection and try again." }
    }

    private func call(_ u: User, video: Bool) async {
        do {
            let id = try await engine.openDM(with: u.id)
            await calls.start(id, video: video)
        } catch { self.error = (error as? APIError)?.message ?? "Check your connection and try again." }
    }
}
