import AsgardKit
import Intents
import SwiftData

/// SiriKit messaging: powers "Hey Siri, send a message to Thor on Asgard",
/// reading messages aloud, and the CarPlay messaging experience.
@MainActor
final class SiriIntentHandler: NSObject, @preconcurrency INSendMessageIntentHandling, @preconcurrency INSearchForMessagesIntentHandling,
    @preconcurrency INSetMessageAttributeIntentHandling, @preconcurrency INStartCallIntentHandling {

    // MARK: Send

    func resolveRecipients(for intent: INSendMessageIntent) async -> [INSendMessageRecipientResolutionResult] {
        if let group = intent.speakableGroupName?.spokenPhrase {
            return { Self.match(group).map { _ in [.success(with: INPerson.group(named: group))] } ?? [.unsupported(forReason: .noAccount)] }()
        }
        guard let people = intent.recipients, !people.isEmpty else { return [.needsValue()] }
        return {
            people.map { p in
                let matches = Self.people(matching: p.displayName)
                switch matches.count {
                case 0: return .unsupported(forReason: .noAccount)
                case 1: return .success(with: matches[0])
                default: return .disambiguation(with: matches)
                }
            }
        }()
    }

    func resolveContent(for intent: INSendMessageIntent) async -> INStringResolutionResult {
        guard let t = intent.content, !t.isEmpty else { return .needsValue() }
        return .success(with: t)
    }

    func handle(intent: INSendMessageIntent) async -> INSendMessageIntentResponse {
        {
            let engine = AppServices.shared.engine
            let convID: UUID? = intent.conversationIdentifier.flatMap(UUID.init(uuidString:))
                ?? intent.speakableGroupName.flatMap { Self.match($0.spokenPhrase) }
                ?? intent.recipients?.first?.personHandle?.value.flatMap(UUID.init(uuidString:))
            guard let convID, let text = intent.content else { return INSendMessageIntentResponse(code: .failure, userActivity: nil) }
            Task { _ = await engine.send(.text(text), to: convID) }
            return INSendMessageIntentResponse(code: .success, userActivity: nil)
        }()
    }

    // MARK: Read (Siri reads unread messages; used by CarPlay)

    func handle(intent: INSearchForMessagesIntent) async -> INSearchForMessagesIntentResponse {
        {
            let engine = AppServices.shared.engine
            let convs = ((try? engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []).filter { $0.unread > 0 && !$0.isMuted }
            var out: [INMessage] = []
            for c in convs {
                let id = c.id
                var d = FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.conversationID == id }, sortBy: [SortDescriptor(\.sortKey, order: .reverse)])
                d.fetchLimit = c.unread
                for m in ((try? engine.context.fetch(d)) ?? []).reversed() where m.senderUserID != engine.myID {
                    let sender = INPerson(personHandle: INPersonHandle(value: m.conversationID.lower, type: .unknown), nameComponents: nil,
                                          displayName: engine.name(m.senderUserID), image: nil, contactIdentifier: nil, customIdentifier: m.senderUserID?.lower)
                    out.append(INMessage(identifier: m.id.lower, conversationIdentifier: c.id.lower, content: m.content.map(ChatEngine.preview),
                                         dateSent: m.sentAt, sender: sender, recipients: nil, groupName: c.kind == .dm ? nil : INSpeakableString(spokenPhrase: c.title),
                                         messageType: .text))
                }
            }
            let r = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
            r.messages = out
            return r
        }()
    }

    func handle(intent: INSetMessageAttributeIntent) async -> INSetMessageAttributeIntentResponse {
        {
            let engine = AppServices.shared.engine
            for id in intent.identifiers ?? [] {
                guard let uuid = UUID(uuidString: id), let m = try? engine.context.fetch(FetchDescriptorFactory.message(uuid)).first else { continue }
                if intent.attribute == .read { engine.markRead(m.conversationID) }
            }
            return INSetMessageAttributeIntentResponse(code: .success, userActivity: nil)
        }()
    }

    // MARK: Calls (CarPlay / Siri "call Freya on Asgard")

    func resolveContacts(for intent: INStartCallIntent) async -> [INStartCallContactResolutionResult] {
        guard let people = intent.contacts, !people.isEmpty else { return [.needsValue()] }
        return {
            people.map { p in
                let m = Self.people(matching: p.displayName)
                return m.count == 1 ? .success(with: m[0]) : m.isEmpty ? .unsupported() : .disambiguation(with: m)
            }
        }()
    }

    func handle(intent: INStartCallIntent) async -> INStartCallIntentResponse {
        let activity = NSUserActivity(activityType: "INStartCallIntent")
        return INStartCallIntentResponse(code: .continueInApp, userActivity: activity)
    }

    // MARK: Matching

    @MainActor static func people(matching name: String) -> [INPerson] {
        let engine = AppServices.shared.engine
        let convs = ((try? engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []).filter { $0.kind == .dm }
        return convs.filter { $0.title.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.title) }.map { c in
            INPerson(personHandle: INPersonHandle(value: c.id.lower, type: .unknown), nameComponents: nil, displayName: c.title, image: nil,
                     contactIdentifier: nil, customIdentifier: c.conversation?.peer?.id.lower)
        }
    }

    @MainActor static func match(_ group: String) -> UUID? {
        let convs = (try? AppServices.shared.engine.context.fetch(FetchDescriptor<StoredConversation>())) ?? []
        return convs.first { $0.kind != .dm && $0.title.localizedCaseInsensitiveContains(group) }?.id
    }
}

extension INPerson {
    static func group(named name: String) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: name, type: .unknown), nameComponents: nil, displayName: name, image: nil, contactIdentifier: nil, customIdentifier: nil)
    }
}
