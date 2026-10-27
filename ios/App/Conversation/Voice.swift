import AsgardKit
import AVFoundation
import SwiftUI

/// Records AAC voice notes and samples a 64-point waveform.
@MainActor
@Observable
final class VoiceRecorder {
    struct Recording { var data: Data; var durationMS: Int; var waveform: Data }

    private(set) var isRecording = false
    private(set) var locked = false
    private(set) var levels: [Float] = []
    private(set) var started: Date?
    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private var url: URL?

    func start() async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        rec.isMeteringEnabled = true
        rec.record()
        recorder = rec
        self.url = url
        levels = []
        started = .now
        isRecording = true
        Haptics.tap()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                self.levels.append(max(0, min(1, (db + 50) / 50)))
            }
        }
    }

    func lock() { locked = true; Haptics.tap() }

    func cancel() {
        meter?.cancel()
        recorder?.stop()
        recorder?.deleteRecording()
        reset()
    }

    func finish() -> Recording? {
        meter?.cancel()
        guard let rec = recorder, let url, let started else { reset(); return nil }
        let duration = Date.now.timeIntervalSince(started)
        rec.stop()
        defer { reset(); try? FileManager.default.removeItem(at: url) }
        guard duration > 0.6, let data = try? Data(contentsOf: url) else { return nil }
        return Recording(data: data, durationMS: Int(duration * 1000), waveform: Self.downsample(levels, to: 64))
    }

    private func reset() {
        recorder = nil
        isRecording = false
        locked = false
        started = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func downsample(_ levels: [Float], to n: Int) -> Data {
        guard !levels.isEmpty else { return Data(repeating: 20, count: n) }
        return Data((0..<n).map { i in
            let lo = i * levels.count / n, hi = max(lo + 1, (i + 1) * levels.count / n)
            let slice = levels[lo..<min(hi, levels.count)]
            return UInt8(min(255, (slice.max() ?? 0) * 255))
        })
    }
}

/// Hold to record; slide up to lock, left to cancel.
struct MicButton: View {
    let recorder: VoiceRecorder
    var onSend: () -> Void
    @State private var drag: CGSize = .zero

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(recorder.isRecording ? Color.white : Color.primary)
            .background { if recorder.isRecording { Circle().fill(Color.red).scaleEffect(1.5) } }
            .glassEffect(.regular.interactive(), in: .circle)
            .offset(drag)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !recorder.isRecording { Task { await recorder.start() } }
                        drag = CGSize(width: min(0, v.translation.width), height: min(0, v.translation.height))
                        if v.translation.height < -80 && !recorder.locked { recorder.lock(); drag = .zero }
                    }
                    .onEnded { v in
                        drag = .zero
                        if recorder.locked { return }
                        if v.translation.width < -100 { recorder.cancel() } else { onSend() }
                    }
            )
            .accessibilityLabel("Hold to record a voice message")
    }
}

struct RecordingBar: View {
    let recorder: VoiceRecorder
    var done: (_ cancel: Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { done(true) } label: { Image(systemName: "trash").foregroundStyle(.red) }
            Circle().fill(.red).frame(width: 10, height: 10).symbolEffect(.pulse)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(Duration.seconds(Date.now.timeIntervalSince(recorder.started ?? .now)).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
            WaveformView(levels: recorder.levels.suffix(40).map { CGFloat($0) }, progress: 1, tint: .accentColor)
                .frame(height: 28)
            if recorder.locked {
                Button { done(false) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
            } else {
                Label("Slide to cancel", systemImage: "chevron.left").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

struct WaveformView: View {
    var levels: [CGFloat]
    var progress: Double
    var tint: Color
    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let w = geo.size.width / CGFloat(count)
            HStack(alignment: .center, spacing: w * 0.35) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(count) <= progress ? tint : tint.opacity(0.35))
                        .frame(width: w * 0.65, height: max(3, geo.size.height * levels[i]))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Plays a voice note with scrubbing and speed control.
@MainActor
@Observable
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()
    private(set) var current: UUID?
    private(set) var progress: Double = 0
    private(set) var playing = false
    var rate: Float = 1
    private var player: AVAudioPlayer?
    private var timer: Task<Void, Never>?

    func toggle(_ id: UUID, data: Data) {
        if current == id, let p = player {
            if p.isPlaying { p.pause(); playing = false } else { p.play(); playing = true }
            return
        }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.enableRate = true
        p.rate = rate
        p.delegate = self
        p.play()
        player = p
        current = id
        playing = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let p = self.player else { return }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
            }
        }
    }

    func seek(_ fraction: Double) {
        guard let p = player else { return }
        p.currentTime = p.duration * fraction
        progress = fraction
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        player?.rate = rate
    }

    func stop() {
        timer?.cancel()
        player?.stop()
        player = nil
        current = nil
        playing = false
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct VoiceNotePlayer: View {
    let attachment: MessageContent.Attachment
    let mine: Bool
    @Environment(ChatEngine.self) private var engine
    @State private var loading = false
    @State private var failed = false
    private var playback: AudioPlayback { .shared }

    var isCurrent: Bool { playback.current == attachment.mediaID }

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await play() } } label: {
                ZStack {
                    Circle().fill(mine ? Color.white : Color.accentColor).frame(width: 40, height: 40)
                    if loading { ProgressView().tint(mine ? .accentColor : .white) } else {
                        Image(systemName: isCurrent && playback.playing ? "pause.fill" : "play.fill")
                            .foregroundStyle(mine ? Color.accentColor : Color.white)
                    }
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                WaveformView(levels: (attachment.waveform ?? Data(repeating: 40, count: 40)).map { CGFloat($0) / 255 },
                             progress: isCurrent ? playback.progress : 0, tint: mine ? .white : .accentColor)
                    .frame(width: 170, height: 26)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in if isCurrent { playback.seek(max(0, min(1, v.location.x / 170))) } })
                HStack {
                    Text(Duration.milliseconds(attachment.durationMS ?? 0).formatted(.time(pattern: .minuteSecond))).font(.caption2).monospacedDigit()
                    if failed { Text("Unavailable").font(.caption2) }
                }
                .opacity(0.8)
            }
            if isCurrent {
                Button { playback.cycleRate() } label: {
                    Text(playback.rate == 1 ? "1×" : playback.rate == 1.5 ? "1.5×" : "2×").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.white.opacity(0.2), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    func play() async {
        if isCurrent { playback.toggle(attachment.mediaID, data: Data()); return }
        loading = true
        defer { loading = false }
        guard let data = try? await engine.attachmentData(attachment) else { failed = true; return }
        playback.toggle(attachment.mediaID, data: data)
    }
}
