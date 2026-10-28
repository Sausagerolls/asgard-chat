import AsgardKit
import SwiftUI

/// Sidebar list of everyone on the server, favourites first, with message and call buttons.
struct MacPeopleList: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(MacNavigator.self) private var nav
    @Environment(MacCallManager.self) private var calls
    @State private var people: [User] = []
    @State private var search = ""

    private var filtered: [User] {
        people.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.username.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
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
        .listStyle(.sidebar)
        .overlay {
            if filtered.isEmpty { ContentUnavailableView(search.isEmpty ? "No one else here yet" : "No matches", systemImage: "person.2") }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search people")
        .task { people = await engine.searchUsers("").filter { !$0.isBot } }
    }

    private func row(_ u: User, favourite: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarView(id: u.id, name: u.displayName, mediaID: u.avatarMediaID, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(u.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                Text(u.online ? "Online" : "@" + u.username).font(.caption).foregroundStyle(u.online ? .green : .secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { Task { await engine.setFavorite(u.id, !favourite) } } label: {
                Image(systemName: favourite ? "star.fill" : "star").foregroundStyle(favourite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless).help(favourite ? "Remove from Favourites" : "Add to Favourites")
            Button { Task { await message(u) } } label: { Image(systemName: "message") }
                .buttonStyle(.borderless).help("Message")
            if engine.callsAvailable {
                Button { Task { await call(u, video: false) } } label: { Image(systemName: "phone") }
                    .buttonStyle(.borderless).help("Voice Call")
                Button { Task { await call(u, video: true) } } label: { Image(systemName: "video") }
                    .buttonStyle(.borderless).help("Video Call")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(favourite ? "Remove from Favourites" : "Add to Favourites") { Task { await engine.setFavorite(u.id, !favourite) } }
        }
    }

    private func message(_ u: User) async {
        guard let id = try? await engine.openDM(with: u.id) else { engine.banner = "Couldn't open a chat with \(u.displayName)."; return }
        nav.page = .chats
        nav.open(id)
    }

    private func call(_ u: User, video: Bool) async {
        guard let id = try? await engine.openDM(with: u.id) else { engine.banner = "Couldn't call \(u.displayName)."; return }
        nav.selection = id
        await calls.startCall(id, video: video)
    }
}
