import AsgardKit
import CarPlay
import Intents
import SwiftData

/// CarPlay communication app: recent chats you can listen to and reply to by
/// voice, favourites to call, all driven through Siri for safety.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        MainActor.assumeIsolated {
            let people = peopleTemplate()
            let tabs = CPTabBarTemplate(templates: [chatsTemplate(), people, callsTemplate()])
            interfaceController.setRootTemplate(tabs, animated: true, completion: nil)
            Task { await self.loadPeople(into: people) }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    @MainActor func recent(limit: Int) -> [StoredConversation] {
        let d = FetchDescriptor<StoredConversation>(sortBy: [SortDescriptor(\.sortDate, order: .reverse)])
        return ((try? AppServices.shared.engine.context.fetch(d)) ?? []).filter { $0.kind == .dm || $0.kind == .group }.prefix(limit).map { $0 }
    }

    @MainActor func chatsTemplate() -> CPListTemplate {
        let items: [CPMessageListItem] = recent(limit: CPListTemplate.maximumItemCount).map { c in
            let item = CPMessageListItem(conversationIdentifier: c.id.lower, text: c.title,
                                         leadingConfiguration: .init(leadingItem: c.unread > 0 ? .star : .none, leadingImage: nil, unread: c.unread > 0),
                                         trailingConfiguration: .init(trailingItem: c.isMuted ? .mute : .none, trailingImage: nil),
                                         detailText: c.unread > 0 ? "\(c.unread) unread" : c.previewDate?.formatted(date: .omitted, time: .shortened),
                                         trailingText: nil)
            item.phoneOrEmailAddress = nil
            return item
        }
        let t = CPListTemplate(title: "Chats", sections: [CPListSection(items: items)])
        t.tabImage = UIImage(systemName: "bubble.left.and.bubble.right.fill")
        t.emptyViewTitleVariants = ["No chats"]
        return t
    }

    // MARK: People

    @MainActor func peopleTemplate() -> CPListTemplate {
        let t = CPListTemplate(title: "People", sections: [])
        t.tabImage = UIImage(systemName: "person.2.fill")
        t.emptyViewTitleVariants = ["Loading…"]
        return t
    }

    /// Favourites first, then everyone else; picking someone offers a call or a Siri message.
    @MainActor func loadPeople(into t: CPListTemplate) async {
        let engine = AppServices.shared.engine
        let people = await engine.searchUsers("").filter { !$0.isBot }
        let favs = engine.favoriteUserIDs
        func items(_ users: [User]) -> [CPListItem] {
            users.prefix(CPListTemplate.maximumItemCount).map { u in
                let item = CPListItem(text: u.displayName, detailText: u.online ? "Online" : "@" + u.username,
                                      image: UIImage(systemName: favs.contains(u.id) ? "star.circle.fill" : "person.crop.circle.fill"))
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, done in
                    self?.showContact(u)
                    done()
                }
                return item
            }
        }
        var sections: [CPListSection] = []
        let favourites = people.filter { favs.contains($0.id) }
        if !favourites.isEmpty { sections.append(CPListSection(items: items(favourites), header: "Favourites", sectionIndexTitle: nil)) }
        let others = people.filter { !favs.contains($0.id) }
        if !others.isEmpty { sections.append(CPListSection(items: items(others), header: favourites.isEmpty ? nil : "Everyone", sectionIndexTitle: nil)) }
        t.emptyViewTitleVariants = ["No one else here yet"]
        t.updateSections(sections)
    }

    @MainActor func showContact(_ u: User) {
        let contact = CPContact(name: u.displayName, image: UIImage(systemName: "person.crop.circle.fill")!)
        contact.subtitle = "@" + u.username
        var buttons: [CPButton] = []
        if AppServices.shared.engine.callsAvailable {
            buttons.append(CPContactCallButton { [weak self] _ in
                Task { @MainActor in
                    guard let id = try? await AppServices.shared.engine.openDM(with: u.id) else { return }
                    await AppServices.shared.calls.start(id, video: false)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                }
            })
        }
        // Messages in CarPlay go through Siri; it matches the person by name.
        buttons.append(CPContactMessageButton(phoneOrEmail: u.displayName))
        contact.actions = buttons
        interfaceController?.pushTemplate(CPContactTemplate(contact: contact), animated: true, completion: nil)
    }

    @MainActor func callsTemplate() -> CPListTemplate {
        let items: [CPListItem] = recent(limit: 12).filter { $0.kind == .dm }.map { c in
            let item = CPListItem(text: c.title, detailText: "Asgard audio call", image: UIImage(systemName: "phone.circle.fill"))
            let id = c.id
            item.handler = { _, done in
                Task { @MainActor in
                    await AppServices.shared.calls.start(id, video: false)
                    done()
                }
            }
            return item
        }
        let t = CPListTemplate(title: "Calls", sections: [CPListSection(items: items)])
        t.tabImage = UIImage(systemName: "phone.fill")
        return t
    }
}
