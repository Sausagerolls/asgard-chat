import AppKit
import AsgardKit
import LiveKit
import SwiftUI
import UserNotifications

/// One call or voice room this Mac is in.
@MainActor
@Observable
final class MacCall: Identifiable {
    let id = UUID()
    let conversationID: UUID
    let title: String
    let isVoiceRoom: Bool
    let outgoing: Bool
    var muted = false
    var cameraOn: Bool
    var sharingScreen = false
    var connectedAt: Date?
    var state = "Connecting…"
    var room = Room()
    var participants: [RemoteParticipant] = []
    var revision = 0

    init(conversationID: UUID, title: String, isVoiceRoom: Bool, outgoing: Bool, video: Bool) {
        self.conversationID = conversationID
        self.title = title
        self.isVoiceRoom = isVoiceRoom
        self.outgoing = outgoing
        cameraOn = video
    }
}

/// Calls and voice rooms on the Mac. Same server flow and end-to-end media
/// encryption as iPhone, without CallKit: ringing shows a sheet and a notification.
@MainActor
@Observable
final class MacCallManager: NSObject {
    var active: MacCall?
    var ringing: ChatEngine.IncomingCall?
    private let engine: ChatEngine
    private var heartbeat: Task<Void, Never>?

    init(engine: ChatEngine) {
        self.engine = engine
        super.init()
    }

    // MARK: Start

    func startCall(_ conv: UUID, video: Bool) async {
        guard await prepare() else { return }
        let call = MacCall(conversationID: conv, title: engine.storedConversation(conv)?.title ?? "Call", isVoiceRoom: false, outgoing: true, video: video)
        active = call
        await connect(call)
    }

    func joinVoiceRoom(_ conv: UUID, video: Bool) async {
        if let a = active, a.isVoiceRoom, a.conversationID == conv { return }
        guard await prepare() else { return }
        let call = MacCall(conversationID: conv, title: engine.storedConversation(conv)?.title ?? "Voice room", isVoiceRoom: true, outgoing: true, video: video)
        active = call
        await connect(call)
    }

    func isInVoiceRoom(_ conv: UUID) -> Bool { active.map { $0.isVoiceRoom && $0.conversationID == conv } ?? false }

    /// Leaves any current call first; demo mode has no media server.
    private func prepare() async -> Bool {
        if active != nil { await hangUp() }
        if engine.isDemo { engine.banner = "Calls need a real server."; return false }
        return true
    }

    // MARK: Incoming

    func ring(_ call: ChatEngine.IncomingCall) {
        guard active == nil else { return }
        ringing = call
        let content = UNMutableNotificationContent()
        content.title = call.callerName
        content.body = call.video ? "Incoming video call" : "Incoming call"
        content.sound = .default
        content.userInfo = ["c": call.conversationID.lower]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-" + call.id.uuidString, content: content, trigger: nil))
        NSApp.requestUserAttention(.criticalRequest)
    }

    func accept(video: Bool) async {
        guard let r = ringing else { return }
        ringing = nil
        let call = MacCall(conversationID: r.conversationID, title: engine.storedConversation(r.conversationID)?.title ?? r.callerName,
                           isVoiceRoom: false, outgoing: false, video: video && r.video)
        active = call
        engine.incomingCall = nil
        await connect(call)
    }

    func decline() async {
        guard let r = ringing else { return }
        ringing = nil
        engine.incomingCall = nil
        await engine.endCall(r.conversationID, reason: "declined", all: engine.conversation(r.conversationID)?.kind == .dm)
        engine.recordCall(r.conversationID, video: r.video, outgoing: false, duration: 0, missed: true)
    }

    func remoteEnded(_ conv: UUID) {
        if ringing?.conversationID == conv {
            if let r = ringing { engine.recordCall(conv, video: r.video, outgoing: false, duration: 0, missed: true) }
            ringing = nil
        }
        if let c = active, !c.isVoiceRoom, c.conversationID == conv { Task { await teardown(c, notifyServer: false) } }
    }

    // MARK: Media

    private func connect(_ call: MacCall) async {
        do {
            let url: String, token: String, key: Data?
            if call.isVoiceRoom {
                let (join, k) = try await engine.joinVoice(call.conversationID, muted: call.muted, video: call.cameraOn)
                (url, token, key) = (join.url, join.token, k)
            } else {
                let join = try await engine.startCall(call.conversationID, video: call.cameraOn)
                (url, token) = (join.url, join.token)
                key = await waitForKey(join.room)
            }
            guard let key else {
                throw APIError(status: 0, code: "no_room_key", message: "Couldn't get the call's encryption key. Try again in a moment.")
            }
            let provider = BaseKeyProvider(isSharedKey: true)
            provider.setKey(key: key.base64EncodedString())
            call.room = Room(delegate: self, roomOptions: RoomOptions(adaptiveStream: true, dynacast: true, encryptionOptions: EncryptionOptions(keyProvider: provider)))
            try await call.room.connect(url: url, token: token)
            try await call.room.localParticipant.setMicrophone(enabled: !call.muted)
            if call.cameraOn { try await call.room.localParticipant.setCamera(enabled: true) }
            if call.isVoiceRoom || !call.room.remoteParticipants.isEmpty { markConnected(call) } else { call.state = "Ringing…" }
            refresh(call.room)
            if call.isVoiceRoom {
                let conv = call.conversationID
                heartbeat = Task { [engine] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        await engine.updateVoice(conv)
                    }
                }
            }
        } catch {
            engine.banner = (error as? APIError)?.message ?? "Couldn't connect."
            await teardown(call, notifyServer: true)
        }
    }

    private func waitForKey(_ room: String) async -> Data? {
        for _ in 0..<30 {
            if let k = CallKeyStore.shared.key(for: room) { return k }
            await engine.syncNow()
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    private func markConnected(_ call: MacCall) {
        guard call.connectedAt == nil else { return }
        call.connectedAt = .now
        call.state = "Connected"
    }

    // MARK: Controls

    func toggleMute() {
        guard let c = active else { return }
        c.muted.toggle()
        Task { try? await c.room.localParticipant.setMicrophone(enabled: !c.muted) }
        if c.isVoiceRoom { Task { await engine.updateVoice(c.conversationID, muted: c.muted) } }
    }

    func toggleCamera() {
        guard let c = active else { return }
        c.cameraOn.toggle()
        Task { try? await c.room.localParticipant.setCamera(enabled: c.cameraOn) }
        if c.isVoiceRoom { Task { await engine.updateVoice(c.conversationID, video: c.cameraOn) } }
    }

    func toggleScreenShare() {
        guard let c = active else { return }
        c.sharingScreen.toggle()
        let on = c.sharingScreen
        Task {
            do { try await c.room.localParticipant.setScreenShare(enabled: on) } catch {
                c.sharingScreen = false
                engine.banner = "Allow Asgard in System Settings › Privacy & Security › Screen & System Audio Recording."
            }
        }
    }

    func hangUp() async {
        guard let c = active else { return }
        await teardown(c, notifyServer: true)
    }

    private func teardown(_ call: MacCall, notifyServer: Bool) async {
        let duration = call.connectedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        heartbeat?.cancel()
        heartbeat = nil
        await call.room.disconnect()
        if call.isVoiceRoom {
            await engine.leaveVoice(call.conversationID)
        } else {
            if notifyServer {
                await engine.endCall(call.conversationID, reason: "hangup", all: engine.conversation(call.conversationID)?.kind == .dm || call.participants.isEmpty)
            }
            engine.recordCall(call.conversationID, video: call.cameraOn, outgoing: call.outgoing, duration: duration, missed: false)
        }
        if active === call { active = nil }
    }

    fileprivate func refresh(_ room: Room) {
        guard let call = active, call.room === room else { return }
        call.participants = Array(room.remoteParticipants.values)
        call.revision += 1
        if !call.participants.isEmpty { markConnected(call) }
    }
}

extension MacCallManager: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in refresh(room) }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            refresh(room)
            if let c = active, c.room === room, !c.isVoiceRoom, room.remoteParticipants.isEmpty, c.connectedAt != nil,
               engine.conversation(c.conversationID)?.kind == .dm {
                await teardown(c, notifyServer: true)
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
        Task { @MainActor in if let c = active, c.room === room { c.revision += 1 } }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in refresh(room) }
    }
}

// MARK: - Views

struct MacCallWindow: View {
    @Environment(MacCallManager.self) private var calls
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.9)
            if let call = calls.active {
                VStack(spacing: 0) {
                    HStack {
                        Label(call.title, systemImage: call.isVoiceRoom ? "speaker.wave.2.fill" : "phone.fill").font(.headline)
                        Spacer()
                        if let t = call.connectedAt { Text(t, style: .timer).monospacedDigit().foregroundStyle(.secondary) } else { Text(call.state).foregroundStyle(.secondary) }
                        Label("Encrypted", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                    }
                    .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 10)
                    MacCallStage(call: call)
                    MacCallControls(call: call)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "phone.down.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No call in progress").foregroundStyle(.secondary)
                }
                .task { try? await Task.sleep(for: .seconds(1)); dismissWindow(id: "call") }
            }
        }
        .onChange(of: calls.active == nil) { _, ended in if ended { dismissWindow(id: "call") } }
    }
}

struct MacCallStage: View {
    let call: MacCall
    @Environment(ChatEngine.self) private var engine

    struct Tile: Identifiable {
        var id: String
        var userID: UUID?
        var name: String
        var video: VideoTrack?
        var speaking: Bool
        var muted: Bool
        var isMe: Bool
    }

    var tiles: [Tile] {
        let _ = call.revision
        let local = call.room.localParticipant
        var out: [Tile] = []
        for p in call.participants {
            let parts = (p.identity?.stringValue ?? "").split(separator: ":").map(String.init)
            let device = parts.count == 2 ? UUID(uuidString: parts[1]) : nil
            let info = engine.voiceParticipants(call.conversationID).first { $0.deviceID == device }
            let screen = p.videoTracks.first { $0.source == .screenShareVideo }?.track as? VideoTrack
            out.append(Tile(id: p.sid?.stringValue ?? UUID().uuidString, userID: parts.first.flatMap(UUID.init(uuidString:)), name: p.name ?? info?.name ?? "Someone",
                            video: screen ?? p.firstCameraVideoTrack, speaking: p.isSpeaking, muted: info?.muted ?? !p.isMicrophoneEnabled(), isMe: false))
        }
        out.append(Tile(id: "me", userID: engine.myID, name: "You", video: call.cameraOn ? local.firstCameraVideoTrack : nil,
                        speaking: local.isSpeaking && !call.muted, muted: call.muted, isMe: true))
        return out
    }

    var body: some View {
        let tiles = tiles
        GeometryReader { geo in
            let cols = tiles.count <= 1 ? 1 : tiles.count <= 4 ? 2 : 3
            let rows = (tiles.count + cols - 1) / cols
            let h = max(140, (geo.size.height - CGFloat(rows - 1) * 10) / CGFloat(rows))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 10) {
                ForEach(tiles) { t in
                    ZStack(alignment: .bottomLeading) {
                        if let v = t.video {
                            SwiftUIVideoView(v, layoutMode: .fit, mirrorMode: t.isMe ? .mirror : .off)
                        } else {
                            Rectangle().fill(.black.opacity(0.3)).overlay(AvatarView(id: t.userID, name: t.name, size: min(110, h * 0.45)))
                        }
                        HStack(spacing: 4) {
                            if t.muted { Image(systemName: "mic.slash.fill").foregroundStyle(.red) }
                            Text(t.name)
                        }
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.45), in: .capsule).padding(8)
                    }
                    .frame(height: h)
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.teal, lineWidth: t.speaking ? 3 : 0))
                    .animation(.easeOut(duration: 0.15), value: t.speaking)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct MacCallControls: View {
    let call: MacCall
    @Environment(MacCallManager.self) private var calls

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                control(call.muted ? "mic.slash.fill" : "mic.fill", active: call.muted, help: call.muted ? "Unmute" : "Mute") { calls.toggleMute() }
                    .keyboardShortcut("d", modifiers: [.command])
                control(call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn, help: "Camera") { calls.toggleCamera() }
                    .keyboardShortcut("e", modifiers: [.command])
                control("rectangle.on.rectangle", active: call.sharingScreen, help: "Share Screen") { calls.toggleScreenShare() }
                AudioDevicesMenu()
                Button { Task { await calls.hangUp() } } label: {
                    Label(call.isVoiceRoom ? "Leave" : "End", systemImage: "phone.down.fill").font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 46)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.red).interactive(), in: .capsule)
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
        .padding(.vertical, 18)
    }

    func control(_ icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 46, height: 46).foregroundStyle(active ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(.white).interactive() : .regular.interactive(), in: .circle)
        .help(help)
    }
}

struct AudioDevicesMenu: View {
    var body: some View {
        Menu {
            Section("Microphone") {
                ForEach(AudioManager.shared.inputDevices, id: \.deviceId) { d in
                    Button(d.name) { AudioManager.shared.inputDevice = d }
                }
            }
            Section("Speaker") {
                ForEach(AudioManager.shared.outputDevices, id: \.deviceId) { d in
                    Button(d.name) { AudioManager.shared.outputDevice = d }
                }
            }
        } label: {
            Image(systemName: "hifispeaker.and.homepod").font(.title3).frame(width: 46, height: 46)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Audio Devices")
    }
}

struct IncomingCallSheet: View {
    let call: ChatEngine.IncomingCall
    @Environment(MacCallManager.self) private var calls
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        VStack(spacing: 16) {
            AvatarView(id: call.callerID, name: call.callerName, mediaID: engine.user(call.callerID)?.avatarMediaID, size: 88)
            Text(call.callerName).font(.title2.bold())
            Text(call.video ? "Incoming video call" : "Incoming call").foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button(role: .destructive) { Task { await calls.decline() } } label: { Label("Decline", systemImage: "phone.down.fill").frame(width: 110) }
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                if call.video {
                    Button { Task { await calls.accept(video: true) } } label: { Label("Video", systemImage: "video.fill").frame(width: 110) }
                        .controlSize(.large)
                }
                Button { Task { await calls.accept(video: false) } } label: { Label("Answer", systemImage: "phone.fill").frame(width: 110) }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.green).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 420)
    }
}

/// Drop-in strip at the top of a group or channel.
struct MacVoiceRoomBar: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(MacCallManager.self) private var calls
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let people = engine.voiceParticipants(conversationID)
        let inRoom = calls.isInVoiceRoom(conversationID)
        HStack(spacing: 10) {
            Image(systemName: people.isEmpty ? "speaker.wave.2" : "speaker.wave.2.fill")
                .foregroundStyle(people.isEmpty ? Color.secondary : Brand.teal)
                .symbolEffect(.variableColor.iterative, isActive: !people.isEmpty)
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice room").font(.callout.weight(.semibold))
                Text(people.isEmpty ? "Nobody's here. Drop in any time." : people.map(\.name).formatted(.list(type: .and)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: -8) {
                ForEach(people.prefix(5)) { p in
                    AvatarView(id: p.userID, name: p.name, size: 24).overlay(Circle().stroke(.background, lineWidth: 2))
                        .help(p.name + (p.muted ? " (muted)" : ""))
                }
            }
            Spacer()
            if inRoom {
                Button("Open") { openWindow(id: "call") }
                Button("Leave", role: .destructive) { Task { await calls.hangUp() } }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button { Task { await calls.joinVoiceRoom(conversationID, video: true) } } label: { Image(systemName: "video") }.help("Join with Video")
                Button("Join") { Task { await calls.joinVoiceRoom(conversationID, video: false) } }.buttonStyle(.borderedProminent).tint(Brand.teal)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(inRoom ? .regular.tint(Brand.teal.opacity(0.25)) : .regular, in: .rect(cornerRadius: 16))
        .task(id: conversationID) { await engine.refreshVoiceRoom(conversationID) }
    }
}
