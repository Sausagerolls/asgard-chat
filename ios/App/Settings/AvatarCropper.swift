import SwiftUI
import UIKit

/// Lets the user drag and pinch a photo inside a circle before it becomes an
/// avatar. Returns a square image of `side` pixels.
struct AvatarCropper: View {
    let image: UIImage
    var side: CGFloat = 640
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let circle = min(geo.size.width, geo.size.height) - 48
            let base = baseSize(for: circle)
            let scale = max(1, zoom * pinch)
            let current = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), scale: scale, base: base, circle: circle)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: base.width * scale, height: base.height * scale)
                    .offset(current)
                // Dim everything outside the circle.
                Rectangle().fill(.black.opacity(0.55))
                    .mask {
                        Rectangle().overlay(Circle().frame(width: circle, height: circle).blendMode(.destinationOut))
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
                Circle().stroke(.white.opacity(0.8), lineWidth: 1).frame(width: circle, height: circle).allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture().updating($drag) { v, s, _ in s = v.translation }
                        .onEnded { v in
                            offset = clamped(CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height),
                                             scale: max(1, zoom), base: base, circle: circle)
                        },
                    MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { v in
                            zoom = min(6, max(1, zoom * v.magnification))
                            offset = clamped(offset, scale: zoom, base: base, circle: circle)
                        }
                )
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        onDone(render(scale: max(1, zoom), offset: offset, base: base, circle: circle))
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Move and scale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    /// Size at zoom 1: the image just covers the circle.
    private func baseSize(for circle: CGFloat) -> CGSize {
        let s = image.size
        let fill = circle / min(s.width, s.height)
        return CGSize(width: s.width * fill, height: s.height * fill)
    }

    /// Keeps the circle covered by the image.
    private func clamped(_ o: CGSize, scale: CGFloat, base: CGSize, circle: CGFloat) -> CGSize {
        let maxX = max(0, (base.width * scale - circle) / 2)
        let maxY = max(0, (base.height * scale - circle) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    private func render(scale: CGFloat, offset: CGSize, base: CGSize, circle: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let k = side / circle
            let w = base.width * scale * k, h = base.height * scale * k
            // UIImage.draw respects orientation, so rotated camera photos come out upright.
            image.draw(in: CGRect(x: (side - w) / 2 + offset.width * k, y: (side - h) / 2 + offset.height * k, width: w, height: h))
        }
    }
}

extension View {
    /// Presents the cropper when `source` is set, then clears it.
    func avatarCropper(_ source: Binding<UIImage?>, side: CGFloat = 640, onDone: @escaping (UIImage) -> Void) -> some View {
        fullScreenCover(isPresented: Binding(get: { source.wrappedValue != nil }, set: { if !$0 { source.wrappedValue = nil } })) {
            if let image = source.wrappedValue {
                NavigationStack { AvatarCropper(image: image, side: side, onDone: onDone) }
            }
        }
    }
}
