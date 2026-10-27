import SwiftUI

/// Scroll speed shared with every message row, so bubbles can spread apart and
/// spring back as the list moves. Only the row modifiers observe it, so the
/// list itself is not re-evaluated on every scroll frame.
@MainActor
@Observable
final class ScrollMotion {
    var stretch: CGFloat = 0
    @ObservationIgnored private var lastOffset: CGFloat?
    @ObservationIgnored private var settle: Task<Void, Never>?

    func scrolled(to offset: CGFloat) {
        defer { lastOffset = offset }
        guard let last = lastOffset else { return }
        let delta = offset - last
        guard abs(delta) > 0.5, abs(delta) < 400 else { return } // ignore jumps (scrollTo, loading older)
        stretch = max(-14, min(14, stretch * 0.6 + delta * 0.35))
        settle?.cancel()
        settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { stretch = 0 }
        }
    }
}

/// Remembers which messages already played their arrival animation, so rows
/// recycled by the lazy stack don't animate again.
final class ArrivalTracker {
    let openedAt = Date.now
    private var initial: Set<UUID>?
    private var played: Set<UUID> = []

    func start(with ids: [UUID]) { if initial == nil { initial = Set(ids) } }

    /// True once for a message that arrived while the chat was open.
    func shouldAnimate(_ id: UUID, sentAt: Date) -> Bool {
        guard let initial, !initial.contains(id), !played.contains(id), sentAt > openedAt.addingTimeInterval(-2) else { return false }
        played.insert(id)
        return true
    }
}

struct MessageMotion: ViewModifier {
    let mine: Bool
    @Environment(ScrollMotion.self) private var motion
    /// Captured once per bubble: later redraws must not cut the animation short.
    @State private var landed: Bool

    init(mine: Bool, arriving: Bool) {
        self.mine = mine
        _landed = State(initialValue: !arriving)
    }

    func body(content: Content) -> some View {
        let hidden = !landed
        let stretch = motion.stretch
        content
            .scaleEffect(hidden ? 0.55 : 1, anchor: mine ? .bottomTrailing : .bottomLeading)
            .offset(x: hidden && !mine ? -36 : 0, y: hidden ? (mine ? 70 : 18) : 0)
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 6 : 0)
            // Spread out while scrolling: rows further from the middle move more.
            .visualEffect { view, proxy in
                let frame = proxy.frame(in: .scrollView(axis: .vertical))
                let height = proxy.bounds(of: .scrollView(axis: .vertical))?.height ?? 800
                let fromMiddle = (frame.midY - height / 2) / max(height / 2, 1)
                return view.offset(y: stretch * fromMiddle)
            }
            // Soft edges where bubbles slide under the header and composer.
            .scrollTransition(topLeading: .interactive, bottomTrailing: .interactive) { view, phase in
                view
                    .scaleEffect(phase.isIdentity ? 1 : 0.92, anchor: mine ? .trailing : .leading)
                    .opacity(phase.isIdentity ? 1 : 0.35)
                    .blur(radius: phase.isIdentity ? 0 : 2)
            }
            .onAppear {
                guard hidden else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { landed = true }
            }
    }
}

extension View {
    @ViewBuilder func messageMotion(enabled: Bool, mine: Bool, arriving: Bool) -> some View {
        if enabled { modifier(MessageMotion(mine: mine, arriving: arriving)) } else { self }
    }
}
