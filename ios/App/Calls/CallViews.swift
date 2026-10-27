import AsgardKit
import LiveKit
import SwiftData
import SwiftUI

struct CallScreen: View {
    let call: ActiveCall
    @Environment(CallManager.self) private var calls
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.9)
            let _ = call.revision
            if call.isVoiceRoom {
                VoiceRoomStage(call: call)
            } else if call.video, let remote = call.participants.first(where: { $0.firstCameraVideoTrack != nil }) {
                if call.participants.count > 1 {
                    VideoGrid(participants: call.participants)
                } else if let track = remote.firstCameraVideoTrack {
                    SwiftUIVideoView(track, layoutMode: .fill).ignoresSafeArea()
                }
            } else {
                VStack(spacing: 18) {
                    let sc = engine.storedConversation(call.conversationID)
                    if let sc { sc.avatar(engine: engine, size: 140) }
                    Text(call.title).font(.largeTitle.bold())
                    Group {
                        if let t = call.connectedAt {
                            Text(t, style: .timer).monospacedDigit()
                        } else {
                            Text(call.state)
                        }
                    }
                    .font(.title3).foregroundStyle(.secondary)
                    Label("End-to-end encrypted", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    if call.participants.count > 1 {
                        HStack(spacing: -10) {
                            ForEach(call.participants.prefix(6), id: \.sid) { p in
                                AvatarView(id: nil, name: p.name ?? "?", size: 40)
                                    .overlay(Circle().stroke(p.isSpeaking ? Brand.teal : .clear, lineWidth: 3))
                            }
                        }
                    }
                }
            }
            if !call.isVoiceRoom, call.cameraOn, let local = call.room.localParticipant.firstCameraVideoTrack {
                SwiftUIVideoView(local, layoutMode: .fill, mirrorMode: .mirror)
                    .frame(width: 110, height: 160).clipShape(.rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.3)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 60).padding(.trailing, 16)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44) }
                        .glassEffect(.regular.interactive(), in: .circle)
                    Spacer()
                    if call.isVoiceRoom {
                        VStack(spacing: 0) {
                            Label(call.title, systemImage: "speaker.wave.2.fill").font(.headline).lineLimit(1)
                            Label("End-to-end encrypted", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if call.video { Text(call.connectedAt.map { _ in call.title } ?? call.state).font(.headline) }
                    Spacer()
                    SwiftUIAudioRoutePickerButton().frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
                }
                .padding()
                Spacer()
                GlassEffectContainer(spacing: 18) {
                    HStack(spacing: 18) {
                        CallButton(icon: call.muted ? "mic.slash.fill" : "mic.fill", active: call.muted) { calls.toggleMute() }
                        CallButton(icon: call.cameraOn ? "video.fill" : "video.slash.fill", active: !call.cameraOn) { calls.toggleCamera() }
                        if call.cameraOn { CallButton(icon: "arrow.triangle.2.circlepath.camera", active: false) { calls.flipCamera() } }
                        CallButton(icon: call.speaker ? "speaker.wave.3.fill" : "speaker.fill", active: call.speaker) { calls.toggleSpeaker() }
                        Button { calls.hangUp() } label: {
                            Image(systemName: "phone.down.fill").font(.title2).foregroundStyle(.white).frame(width: 68, height: 68)
                        }
                        .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                        .accessibilityLabel(call.isVoiceRoom ? "Leave voice room" : "End call")
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onChange(of: calls.active == nil) { _, ended in if ended { dismiss() } }
        .statusBarHidden(call.video)
    }
}

struct VideoGrid: View {
    let participants: [RemoteParticipant]
    var body: some View {
        let cols = participants.count <= 2 ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols), spacing: 6) {
            ForEach(participants, id: \.sid) { p in
                ZStack(alignment: .bottomLeading) {
                    if let t = p.firstCameraVideoTrack { SwiftUIVideoView(t, layoutMode: .fill) } else {
                        Rectangle().fill(.black.opacity(0.4)).overlay(AvatarView(id: nil, name: p.name ?? "?", size: 64))
                    }
                    Text(p.name ?? "").font(.caption.bold()).padding(6).background(.black.opacity(0.4), in: .capsule).padding(6).foregroundStyle(.white)
                }
                .aspectRatio(3 / 4, contentMode: .fill)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.isSpeaking ? Brand.teal : .clear, lineWidth: 3))
            }
        }
        .padding(8).padding(.top, 60)
    }
}

struct CallButton: View {
    let icon: String
    let active: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).frame(width: 60, height: 60).foregroundStyle(active ? Color.black : Color.white)
        }
        .glassEffect(active ? .regular.tint(.white).interactive() : .regular.interactive(), in: .circle)
    }
}

struct OngoingCallAccessory: View {
    let call: ActiveCall
    @Environment(CallManager.self) private var calls
    var body: some View {
        Button { calls.presentedCall = call } label: {
            HStack {
                Image(systemName: call.video ? "video.fill" : "phone.fill").foregroundStyle(Brand.teal)
                Text(call.title).font(.subheadline.bold())
                Spacer()
                if let t = call.connectedAt { Text(t, style: .timer).monospacedDigit().font(.subheadline) } else { Text(call.state).font(.subheadline) }
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

struct CallsTab: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(CallManager.self) private var calls
    @Query(sort: \StoredCall.startedAt, order: .reverse) private var history: [StoredCall]
    @State private var missedOnly = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(history.filter { !missedOnly || $0.missed }) { c in
                    let sc = engine.storedConversation(c.conversationID)
                    HStack(spacing: 12) {
                        if let sc { sc.avatar(engine: engine, size: 46) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sc?.title ?? "Unknown").font(.headline).foregroundStyle(c.missed ? .red : .primary)
                            Label {
                                Text(c.missed ? "Missed" : c.outgoing ? "Outgoing" : "Incoming")
                                + Text(c.duration > 0 ? " · " + Duration.seconds(c.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) : "")
                            } icon: {
                                Image(systemName: c.outgoing ? "arrow.up.right" : "arrow.down.left")
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(c.startedAt.chatListStamp).font(.caption).foregroundStyle(.secondary)
                        Button { Task { await calls.start(c.conversationID, video: c.video) } } label: {
                            Image(systemName: c.video ? "video" : "phone")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { idx in idx.map { history[$0] }.forEach(engine.context.delete); try? engine.context.save() }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackground(intensity: 0.35))
            .overlay { if history.isEmpty { ContentUnavailableView("No calls yet", systemImage: "phone", description: Text("Voice and video calls are end-to-end encrypted.")) } }
            .navigationTitle("Calls")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $missedOnly) { Text("All").tag(false); Text("Missed").tag(true) }.pickerStyle(.segmented).frame(width: 200)
                }
            }
        }
    }
}
