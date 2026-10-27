import AsgardKit
import LiveKit
import SwiftUI

/// Always-visible strip at the top of a group or channel: who is in the voice
/// room, and a one-tap way to drop in or out.
struct VoiceRoomBar: View {
    let conversationID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(CallManager.self) private var calls
    @State private var expanded = false

    var body: some View {
        let people = engine.voiceParticipants(conversationID)
        let inRoom = calls.isInVoiceRoom(conversationID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: people.isEmpty ? "speaker.wave.2" : "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(people.isEmpty ? Color.secondary : Brand.teal)
                    .symbolEffect(.variableColor.iterative, isActive: !people.isEmpty)
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Voice room").font(.subheadline.weight(.semibold))
                            Text(summary(people)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !people.isEmpty && !expanded { FacePile(people: people) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(people.isEmpty)
                Spacer(minLength: 4)
                if inRoom {
                    Button { calls.presentedCall = calls.active } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Open voice room")
                    Button { calls.hangUp() } label: { Text("Leave").font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.glassProminent).tint(.red)
                } else {
                    Menu {
                        Button { join(video: false) } label: { Label("Join with audio", systemImage: "mic.fill") }
                        Button { join(video: true) } label: { Label("Join with video", systemImage: "video.fill") }
                    } label: {
                        Text("Join").font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
                    } primaryAction: { join(video: false) }
                    .buttonStyle(.glassProminent).tint(Brand.teal)
                }
            }
            if expanded && !people.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(people) { p in VoiceParticipantRow(participant: p) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(inRoom ? .regular.tint(Brand.teal.opacity(0.25)) : .regular, in: .rect(cornerRadius: 22))
        .task(id: conversationID) { await engine.refreshVoiceRoom(conversationID) }
        .onChange(of: people.isEmpty) { _, empty in if empty { expanded = false } }
    }

    func summary(_ people: [VoiceParticipant]) -> String {
        switch people.count {
        case 0: return "Nobody's here. Drop in any time."
        case 1: return "\(people[0].name) is here"
        case 2: return "\(people[0].name) and \(people[1].name)"
        default: return "\(people[0].name) and \(people.count - 1) others"
        }
    }

    func join(video: Bool) {
        Haptics.tap()
        Task { await calls.joinVoiceRoom(conversationID, video: video) }
    }
}

struct FacePile: View {
    let people: [VoiceParticipant]
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(people.prefix(4)) { p in
                AvatarView(id: p.userID, name: p.name, size: size)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
            }
            if people.count > 4 {
                Text("+\(people.count - 4)").font(.caption2.bold()).frame(width: size, height: size)
                    .background(.thinMaterial, in: .circle)
            }
        }
    }
}

struct VoiceParticipantRow: View {
    let participant: VoiceParticipant
    var body: some View {
        HStack(spacing: 10) {
            AvatarView(id: participant.userID, name: participant.name, size: 30)
            Text(participant.name).font(.subheadline)
            Spacer()
            if participant.video { Image(systemName: "video.fill").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: participant.muted ? "mic.slash.fill" : "mic.fill")
                .font(.caption).foregroundStyle(participant.muted ? .red : .secondary)
        }
    }
}

/// Small "who's in voice" badge for chat list rows.
struct VoiceRoomBadge: View {
    let count: Int
    var body: some View {
        Label("\(count)", systemImage: "speaker.wave.2.fill")
            .font(.caption2.weight(.bold)).labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Brand.teal.gradient, in: .capsule)
            .accessibilityLabel("\(count) in voice room")
    }
}

/// Full-screen view of a voice room: a tile per person, video when they share
/// it, a glow while they talk.
struct VoiceRoomStage: View {
    let call: ActiveCall
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
        var out = [Tile(id: "me", userID: engine.myID, name: "You", video: call.cameraOn ? local.firstCameraVideoTrack : nil,
                        speaking: local.isSpeaking && !call.muted, muted: call.muted, isMe: true)]
        let state = engine.voiceParticipants(call.conversationID)
        for p in call.participants {
            let identity = p.identity?.stringValue ?? ""
            let parts = identity.split(separator: ":").map(String.init)
            let device = parts.count == 2 ? UUID(uuidString: parts[1]) : nil
            let info = state.first { $0.deviceID == device }
            out.append(Tile(id: identity, userID: parts.first.flatMap(UUID.init(uuidString:)), name: p.name ?? info?.name ?? "Someone",
                            video: p.firstCameraVideoTrack, speaking: p.isSpeaking, muted: info?.muted ?? !p.isMicrophoneEnabled(), isMe: false))
        }
        return out
    }

    var body: some View {
        let tiles = tiles
        let columns = tiles.count <= 1 ? 1 : tiles.count <= 4 ? 2 : 3
        GeometryReader { geo in
            ScrollView {
                if call.connectedAt == nil {
                    Text(call.state).font(.headline).foregroundStyle(.secondary).padding(.top, 8)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                    ForEach(tiles) { t in
                        VoiceTile(tile: t, height: tileHeight(count: tiles.count, columns: columns, in: geo.size))
                    }
                }
                .padding(.horizontal, 12)
                .animation(.snappy, value: tiles.map(\.id))
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 76)
            .padding(.bottom, 120)
        }
    }

    func tileHeight(count: Int, columns: Int, in size: CGSize) -> CGFloat {
        let rows = CGFloat((count + columns - 1) / columns)
        let usable = size.height - 210
        return max(130, min(usable / max(rows, 1) - 10, columns == 1 ? 420 : 260))
    }
}

struct VoiceTile: View {
    let tile: VoiceRoomStage.Tile
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let v = tile.video {
                SwiftUIVideoView(v, layoutMode: .fill, mirrorMode: tile.isMe ? .mirror : .off)
            } else {
                Rectangle().fill(.black.opacity(0.25))
                    .overlay(AvatarView(id: tile.userID, name: tile.name, size: min(96, height * 0.45)))
            }
            HStack(spacing: 4) {
                if tile.muted { Image(systemName: "mic.slash.fill").foregroundStyle(.red) }
                Text(tile.name).lineLimit(1)
            }
            .font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: .capsule)
            .padding(8)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Brand.teal, lineWidth: tile.speaking ? 3 : 0))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.easeOut(duration: 0.15), value: tile.speaking)
    }
}
