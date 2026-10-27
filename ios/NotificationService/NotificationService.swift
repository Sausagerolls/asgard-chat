import AsgardKit
import Intents
import UserNotifications

/// Decrypts incoming pushes on-device and turns them into communication
/// notifications with the sender's name and avatar.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.categoryIdentifier = "MESSAGE"
        best = content
        nonisolated(unsafe) let info = request.content.userInfo
        nonisolated(unsafe) let deliver = contentHandler
        nonisolated(unsafe) let draft = content.mutableCopy() as! UNMutableNotificationContent
        work = Task {
            deliver(await Self.build(draft, info: info))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        if let best, let handler {
            best.body = "New message"
            handler(best)
        }
    }

    static func build(_ content: UNMutableNotificationContent, info: [AnyHashable: Any]) async -> UNNotificationContent {
        guard let account = Keychain.load(), let keys = try? account.deviceKeys() else { return content }
        let api = APIClient(baseURL: account.serverURL, token: account.token)
        guard let convID = (info["c"] as? String).flatMap(UUID.init(uuidString:)) else { return content }
        content.threadIdentifier = convID.lower

        // The envelope is in the push when small enough, otherwise fetch it.
        var envelope: Envelope?
        if let e = info["e"], let data = try? JSONSerialization.data(withJSONObject: e) {
            envelope = try? Coding.decoder.decode(Envelope.self, from: data)
        }
        if envelope == nil, let mid = (info["m"] as? String).flatMap(UUID.init(uuidString:)) {
            envelope = try? await api.history(convID, before: nil, limit: 20).first { $0.id == mid }
        }
        guard let env = envelope, env.kind == "msg", let sender = env.senderUserID else { return content }

        if let dev = env.senderDeviceID, SigningKeyCache.get(dev) == nil, let devices = try? await api.devices(of: sender) {
            SigningKeyCache.put(devices)
        }
        guard case .content(let message, let verified) = EnvelopeOpener(keys: keys).open(env, signingKey: env.senderDeviceID.flatMap(SigningKeyCache.get)) else {
            content.body = "New message"
            return content
        }
        if message.type == .callKey { CallKeyStore.shared.put(room: message.callKey?.room, key: message.callKey?.key) }

        async let userReq: User? = try? api.send("GET", "/users/\(sender.lower)")
        async let convReq: Conversation? = try? api.conversation(convID)
        let user = await userReq, conv = await convReq
        let senderName = user?.displayName ?? "Someone"
        let showPreview = UserDefaults(suiteName: AppGroup.id)?.object(forKey: "notifPreview") as? Bool ?? true
        var body = showPreview ? ChatEngine.preview(message) : "New message"
        if !verified { body = "⚠︎ " + body }
        if message.attachments?.first?.viewOnce == true { body = "View once photo" }
        content.body = body
        content.userInfo = ["c": convID.lower, "m": env.id.lower]
        content.sound = message.silent == true ? nil : .default
        content.relevanceScore = conv?.kind == .dm ? 1 : 0.6
        if let folder = AppGroup.defaults.string(forKey: "focusFolder"), conv?.me?.folder != folder,
           !(conv?.kind == .dm && AppGroup.defaults.bool(forKey: "focusAllowDMs")) {
            content.interruptionLevel = .passive
        }

        // Communication notification: avatar, name and group title rendered by iOS.
        var image: INImage?
        if let avatar = user?.avatarMediaID, let data = try? await api.download(avatar) { image = INImage(imageData: data) }
        let person = INPerson(personHandle: INPersonHandle(value: sender.lower, type: .unknown), nameComponents: nil, displayName: senderName,
                              image: image, contactIdentifier: nil, customIdentifier: sender.lower)
        let isGroup = conv.map { $0.kind != .dm } ?? false
        let me = INPerson(personHandle: INPersonHandle(value: account.userID.lower, type: .unknown), nameComponents: nil, displayName: nil, image: nil,
                          contactIdentifier: nil, customIdentifier: account.userID.lower, isMe: true)
        let intent = INSendMessageIntent(recipients: isGroup ? [me, person] : [me], outgoingMessageType: .outgoingMessageText, content: body,
                                         speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: conv?.title ?? "") : nil,
                                         conversationIdentifier: convID.lower, serviceName: "Asgard", sender: person, attachments: nil)
        if isGroup, let avatarID = conv?.avatarMediaID, let d = try? await api.download(avatarID) {
            intent.setImage(INImage(imageData: d), forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return (try? content.updating(from: intent)) ?? content
    }
}
