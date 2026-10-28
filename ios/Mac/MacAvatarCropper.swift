import AppKit
import SwiftUI

/// Drag to position and use the slider (or pinch) to zoom a photo inside a
/// circle before it becomes an avatar. Returns a square JPEG of `side` pixels.
struct MacAvatarCropper: View {
    let image: NSImage
    var side: CGFloat = 640
    var onDone: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    private let circle: CGFloat = 320

    var body: some View {
        VStack(spacing: 16) {
            Text("Move and scale").font(.headline)
            let base = baseSize
            let current = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), scale: zoom)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: base.width * zoom, height: base.height * zoom)
                    .offset(current)
                Rectangle().fill(.black.opacity(0.55))
                    .mask {
                        Rectangle().overlay(Circle().frame(width: circle, height: circle).blendMode(.destinationOut))
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
                Circle().stroke(.white.opacity(0.8), lineWidth: 1).frame(width: circle, height: circle).allowsHitTesting(false)
            }
            .frame(width: circle + 80, height: circle + 80)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture().updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in offset = clamped(CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height), scale: zoom) }
            )
            .simultaneousGesture(MagnifyGesture().onChanged { v in zoom = min(6, max(1, v.magnification)) })
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...6)
                Image(systemName: "plus.magnifyingglass")
            }
            .frame(width: circle)
            .onChange(of: zoom) { _, z in offset = clamped(offset, scale: z) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose") {
                    if let data = render() { onDone(data) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: circle)
        }
        .padding(24)
    }

    /// Size at zoom 1: the image just covers the circle.
    private var baseSize: CGSize {
        let s = image.size
        let fill = circle / max(1, min(s.width, s.height))
        return CGSize(width: s.width * fill, height: s.height * fill)
    }

    /// Keeps the circle covered by the image.
    private func clamped(_ o: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max(0, (baseSize.width * scale - circle) / 2)
        let maxY = max(0, (baseSize.height * scale - circle) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    private func render() -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let px = Int(side)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let k = side / circle
        let w = baseSize.width * zoom * k, h = baseSize.height * zoom * k
        // Core Graphics has y pointing up, so a downward offset moves the image down by subtracting.
        ctx.draw(cg, in: CGRect(x: (side - w) / 2 + offset.width * k, y: (side - h) / 2 - offset.height * k, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
