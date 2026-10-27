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
            let tabs = CPTabBarTemplate(templates: [chatsTemplate(), callsTemplate()])
            interfaceController.setRootTemplate(tabs, animated: true, completion: nil)
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
