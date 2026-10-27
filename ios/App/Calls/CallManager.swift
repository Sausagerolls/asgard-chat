import ActivityKit
import AsgardKit
import AVFoundation
import CallKit
import LiveKit
import PushKit
import SwiftUI

/// One call in progress (outgoing or answered).
@MainActor
@Observable
final class ActiveCall: Identifiable {
    let id: UUID
    let conversationID: UUID
    let title: String
    var video: Bool
    let outgoing: Bool
    /// A drop-in voice room (group/channel) rather than a ringing call.
    let isVoiceRoom: Bool
    var connectedAt: Date?
    var muted = false
    var cameraOn: Bool
    var speaker: Bool
    var state: String = "Connecting…"
    var participants: [RemoteParticipant] = []
    var room = Room()
    var revision = 0

    init(id: UUID, conversationID: UUID, title: String, video: Bool, outgoing: Bool, isVoiceRoom: Bool = false) {
        self.id = id
        self.conversationID = conversationID
        self.title = title
        self.video = video
        self.outgoing = outgoing
        self.isVoiceRoom = isVoiceRoom
        cameraOn = video
        speaker = video
    }
}

/// Bridges CallKit (native ringing, lock screen, CarPlay), PushKit (VoIP
/// wake-ups) and LiveKit (E2EE media).
@MainActor
@Observable
final class CallManager: NSObject {
    private(set) var active: ActiveCall?
    var presentedCall: ActiveCall?
    private let engine: ChatEngine
    private let provider: CXProvider
    private let controller = CXCallController()
    private var voipRegistry: PKPushRegistry?
    private var hasActivity = false
    private var pendingIncoming: [UUID: ChatEngine.IncomingCall] = [:]
    private var heartbeat: Task<Void, Never>?

    init(engine: ChatEngine) {
        self.engine = engine
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        config.iconTemplateImageData = UIImage(systemName: "bubble.left.and.bubble.right.fill")?.pngData()
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func registerVoIP() {
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        voipRegistry = r
    }

    // MARK: Outgoing

    func start(_ conversationID: UUID, video: Bool) async {
        guard active == nil else { presentedCall = active; return }
        if engine.isDemo {
            let call = ActiveCall(id: UUID(), conversationID: conversationID, title: engine.storedConversation(conversationID)?.title ?? "Call", video: video, outgoing: true)
            call.state = "Demo call"
            call.connectedAt = .now
            active = call
            presentedCall = call
            return
        }
        let title = engine.storedConversation(conversationID)?.title ?? "Call"
        let call = ActiveCall(id: UUID(), conversationID: conversationID, title: title, video: video, outgoing: true)
        active = call
        presentedCall = call
        let handle = CXHandle(type: .generic, value: conversationID.lower)
        let start = CXStartCallAction(call: call.id, handle: handle)
        start.isVideo = video
        start.contactIdentifier = title
        do {
            try await controller.request(CXTransaction(action: start))
        } catch {
            // CallKit unavailable (e.g. simulator restrictions): connect directly.
            await connect(call)
        }
    }

    // MARK: Voice rooms

    /// Drops into a group or channel's voice room. Nobody is rung.
    func joinVoiceRoom(_ conversationID: UUID, video: Bool = false) async {
        if let call = active {
            if call.isVoiceRoom && call.conversationID == conversationID { presentedCall = call; return }
            hangUp()
            while active != nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let title = engine.storedConversation(conversationID)?.title ?? "Voice room"
        let call = ActiveCall(id: UUID(), conversationID: conversationID, title: title, video: video, outgoing: true, isVoiceRoom: true)
        call.state = "Joining…"
        active = call
        presentedCall = call
        if engine.isDemo {
            call.state = "Demo voice room"
            call.connectedAt = .now
            return
        }
        let handle = CXHandle(type: .generic, value: conversationID.lower)
        let start = CXStartCallAction(call: call.id, handle: handle)
        start.isVideo = video
        start.contactIdentifier = title
        do {
            try await controller.request(CXTransaction(action: start))
        } catch {
            await connect(call)
        }
    }

    func isInVoiceRoom(_ conversationID: UUID) -> Bool {
        active.map { $0.isVoiceRoom && $0.conversationID == conversationID } ?? false
    }

    // MARK: Incoming

    func reportIncoming(_ incoming: ChatEngine.IncomingCall) {
        guard active == nil, pendingIncoming[incoming.id] == nil else { return }
        pendingIncoming[incoming.id] = incoming
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: incoming.conversationID.lower)
        update.localizedCallerName = engine.conversation(incoming.conversationID)?.kind == .dm ? incoming.callerName
            : "\(incoming.callerName) · \(engine.storedConversation(incoming.conversationID)?.title ?? "")"
        update.hasVideo = incoming.video
        update.supportsGrouping = false
        update.supportsHolding = false
        provider.reportNewIncomingCall(with: incoming.id, update: update) { _ in }
    }

    func remoteEnded(_ conversationID: UUID) {
        if let p = pendingIncoming.first(where: { $0.value.conversationID == conversationID }) {
            provider.reportCall(with: p.key, endedAt: .now, reason: .remoteEnded)
            engine.recordCall(conversationID, video: p.value.video, outgoing: false, duration: 0, missed: true)
            pendingIncoming[p.key] = nil
        }
        if let call = active, call.conversationID == conversationID {
            provider.reportCall(with: call.id, endedAt: .now, reason: .remoteEnded)
            Task { await teardown(call, notifyServer: false) }
        }
    }

    // MARK: Controls

    func hangUp() {
        guard let call = active else { return }
        if engine.isDemo { Task { await teardown(call, notifyServer: false) }; return }
        Task {
            do { try await controller.request(CXTransaction(action: CXEndCallAction(call: call.id))) }
            catch { await teardown(call, notifyServer: true) }
        }
    }

    func toggleMute() {
        guard let call = active else { return }
        call.muted.toggle()
        Task { try? await call.room.localParticipant.setMicrophone(enabled: !call.muted) }
        if call.isVoiceRoom { Task { await engine.updateVoice(call.conversationID, muted: call.muted) } }
        updateActivity()
    }

    func toggleCamera() {
        guard let call = active else { return }
        call.cameraOn.toggle()
        if call.cameraOn { call.video = true }
        Task { try? await call.room.localParticipant.setCamera(enabled: call.cameraOn) }
        if call.isVoiceRoom { Task { await engine.updateVoice(call.conversationID, video: call.cameraOn) } }
        updateActivity()
    }

    func toggleSpeaker() {
        guard let call = active else { return }
        call.speaker.toggle()
        AudioManager.shared.isSpeakerOutputPreferred = call.speaker
    }

    func flipCamera() {
        guard let call = active,
              let track = call.room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }
        Task { try? await capturer.switchCameraPosition() }
    }

    func toggleScreenShare() {
        guard let call = active else { return }
        let on = call.room.localParticipant.isScreenShareEnabled()
        Task { try? await call.room.localParticipant.setScreenShare(enabled: !on) }
    }

    // MARK: Media

    func connect(_ call: ActiveCall) async {
        if call.isVoiceRoom { await connectVoiceRoom(call); return }
        do {
            let join = try await engine.startCall(call.conversationID, video: call.video)
            var options = RoomOptions(adaptiveStream: true, dynacast: true)
            if let key = await waitForKey(join.room) {
                let provider = BaseKeyProvider(isSharedKey: true)
                provider.setKey(key: key.base64EncodedString())
                options = RoomOptions(adaptiveStream: true, dynacast: true, encryptionOptions: EncryptionOptions(keyProvider: provider))
            }
            call.room = Room(delegate: self, roomOptions: options)
            AudioManager.shared.isSpeakerOutputPreferred = call.speaker
            try await call.room.connect(url: join.url, token: join.token)
            try await call.room.localParticipant.setMicrophone(enabled: true)
            if call.video { try await call.room.localParticipant.setCamera(enabled: true) }
            call.state = call.outgoing && call.room.remoteParticipants.isEmpty ? "Ringing…" : "Connected"
            if !call.room.remoteParticipants.isEmpty { markConnected(call) }
            if call.outgoing { provider.reportOutgoingCall(with: call.id, startedConnectingAt: .now) }
            startActivity(call)
        } catch {
            call.state = "Call failed"
            engine.banner = (error as? APIError)?.message ?? "Couldn't connect the call."
            provider.reportCall(with: call.id, endedAt: .now, reason: .failed)
            await teardown(call, notifyServer: false)
        }
    }

    func connectVoiceRoom(_ call: ActiveCall) async {
        do {
            let (join, key) = try await engine.joinVoice(call.conversationID, muted: call.muted, video: call.video)
            guard let key else {
                throw APIError(status: 0, code: "no_room_key", message: "Couldn't get the voice room's encryption key. Try again in a moment.")
            }
            let keyProvider = BaseKeyProvider(isSharedKey: true)
            keyProvider.setKey(key: key.base64EncodedString())
            let options = RoomOptions(adaptiveStream: true, dynacast: true, encryptionOptions: EncryptionOptions(keyProvider: keyProvider))
            call.room = Room(delegate: self, roomOptions: options)
            AudioManager.shared.isSpeakerOutputPreferred = call.speaker
            try await call.room.connect(url: join.url, token: join.token)
            try await call.room.localParticipant.setMicrophone(enabled: !call.muted)
            if call.video { try await call.room.localParticipant.setCamera(enabled: true) }
            provider.reportOutgoingCall(with: call.id, startedConnectingAt: .now)
            markConnected(call)
            refresh(call.room)
            startActivity(call)
            let conv = call.conversationID
            heartbeat = Task { [engine] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    await engine.updateVoice(conv)
                }
            }
        } catch {
            call.state = "Couldn't join"
            engine.banner = (error as? APIError)?.message ?? "Couldn't join the voice room."
            provider.reportCall(with: call.id, endedAt: .now, reason: .failed)
            await teardown(call, notifyServer: true)
        }
    }

    /// The caller distributes the room key in an encrypted message; give it a moment to arrive.
    func waitForKey(_ room: String) async -> Data? {
        for _ in 0..<30 {
            if let k = CallKeyStore.shared.key(for: room) { return k }
            await engine.syncNow()
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    func markConnected(_ call: ActiveCall) {
        guard call.connectedAt == nil else { return }
        call.connectedAt = .now
        call.state = "Connected"
        if call.outgoing { provider.reportOutgoingCall(with: call.id, connectedAt: .now) }
        updateActivity()
        Haptics.success()
    }

    func teardown(_ call: ActiveCall, notifyServer: Bool) async {
        let duration = call.connectedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        await call.room.disconnect()
        if call.isVoiceRoom {
            heartbeat?.cancel()
            heartbeat = nil
            if !engine.isDemo { await engine.leaveVoice(call.conversationID) }
            if active === call { active = nil }
            if presentedCall === call { presentedCall = nil }
            hasActivity = false
            await Self.endActivities()
            return
        }
        if notifyServer || call.participants.isEmpty {
            await engine.endCall(call.conversationID, reason: "hangup", all: engine.conversation(call.conversationID)?.kind == .dm || call.participants.isEmpty)
        }
        engine.recordCall(call.conversationID, video: call.video, outgoing: call.outgoing, duration: duration, missed: false)
        if active === call { active = nil }
        if presentedCall === call { presentedCall = nil }
        hasActivity = false
        await Self.endActivities()
    }

    // MARK: Live Activity

    // Live Activities (Dynamic Island, Lock Screen) exist on iPhone and iPad only.

    nonisolated static func endActivities() async {
        #if !targetEnvironment(macCatalyst)
        for a in Activity<CallActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    func startActivity(_ call: ActiveCall) {
        #if !targetEnvironment(macCatalyst)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = CallActivityAttributes.ContentState(connectedAt: call.connectedAt, muted: call.muted, video: call.video, participants: call.participants.count + 1)
        hasActivity = (try? Activity.request(attributes: CallActivityAttributes(conversationID: call.conversationID.lower, title: call.title),
                                             content: .init(state: state, staleDate: nil))) != nil
        #endif
    }

    func updateActivity() {
        #if !targetEnvironment(macCatalyst)
        guard let call = active, hasActivity else { return }
        let state = CallActivityAttributes.ContentState(connectedAt: call.connectedAt, muted: call.muted, video: call.video, participants: call.participants.count + 1)
        Task {
            for a in Activity<CallActivityAttributes>.activities { await a.update(.init(state: state, staleDate: nil)) }
        }
        #endif
    }
}

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in if let c = active { await teardown(c, notifyServer: true) } }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let id = action.callUUID
        Task { @MainActor in
            if let call = active, call.id == id { await connect(call) }
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let id = action.callUUID
        Task { @MainActor in
            guard let incoming = pendingIncoming.removeValue(forKey: id) else { return }
            let title = engine.storedConversation(incoming.conversationID)?.title ?? incoming.callerName
            let call = ActiveCall(id: id, conversationID: incoming.conversationID, title: title, video: incoming.video, outgoing: false)
            active = call
            presentedCall = call
            engine.incomingCall = nil
            await connect(call)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let id = action.callUUID
        Task { @MainActor in
            if let incoming = pendingIncoming.removeValue(forKey: id) {
                await engine.endCall(incoming.conversationID, reason: "declined", all: engine.conversation(incoming.conversationID)?.kind == .dm)
                engine.recordCall(incoming.conversationID, video: incoming.video, outgoing: false, duration: 0, missed: true)
            } else if let call = active, call.id == id {
                await teardown(call, notifyServer: true)
            }
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted = action.isMuted
        Task { @MainActor in
            if let call = active, call.muted != muted { toggleMute() }
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}

extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token
        Task { @MainActor in await engine.registerPush(token: nil, voipToken: token) }
    }

    /// iOS requires every VoIP push to be reported to CallKit immediately.
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) async {
        let d = payload.dictionaryPayload
        let conv = (d["conversation_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let caller = (d["caller_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let callID = (d["call_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let call = ChatEngine.IncomingCall(id: callID, conversationID: conv, callerID: caller, callerName: d["caller_name"] as? String ?? "Asgard",
                                           video: d["video"] as? Bool ?? false)
        await MainActor.run { reportIncoming(call) }
    }
}

extension CallManager: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in refresh(room) }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            refresh(room)
            if let call = active, call.room === room, room.remoteParticipants.isEmpty, call.connectedAt != nil,
               engine.conversation(call.conversationID)?.kind == .dm {
                provider.reportCall(with: call.id, endedAt: .now, reason: .remoteEnded)
                await teardown(call, notifyServer: true)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in refresh(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in refresh(room) }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor in
            guard let call = active, call.room === room else { return }
            call.revision += 1
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in refresh(room) }
    }

    @MainActor func refresh(_ room: Room) {
        guard let call = active, call.room === room else { return }
        call.participants = Array(room.remoteParticipants.values)
        call.revision += 1
        if !call.participants.isEmpty { markConnected(call) }
        updateActivity()
    }
}
