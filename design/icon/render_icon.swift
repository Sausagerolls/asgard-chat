// Renders the Asgard Chat app icon in all variants with CoreGraphics.
// Usage: swift design/icon/render_icon.swift <output-dir>
import AppKit
import CoreGraphics

enum Variant: String, CaseIterable { case light, dark, tinted, androidForeground, androidBackground, androidMonochrome, mark }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let violet: UInt32 = 0x8B5CF6, teal: UInt32 = 0x2DD4BF, gold: UInt32 = 0xFBBF24
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func bubblePath(scale s: CGFloat, offset o: CGPoint) -> CGPath {
    // Rounded speech bubble with a tail at bottom-left. Top-left origin coordinates (1024 grid).
    let p = CGMutablePath()
    let rect = CGRect(x: 172, y: 196, width: 680, height: 540)
    let r: CGFloat = 250
    p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: 360, y: rect.maxY))
    // tail
    p.addCurve(to: CGPoint(x: 200, y: 850), control1: CGPoint(x: 320, y: 800), control2: CGPoint(x: 260, y: 840))
    p.addCurve(to: CGPoint(x: 236, y: 690), control1: CGPoint(x: 236, y: 800), control2: CGPoint(x: 250, y: 740))
    p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY - 70))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    p.closeSubpath()
    var t = CGAffineTransform(translationX: o.x, y: o.y).scaledBy(x: s, y: s)
    return p.copy(using: &t)!
}

func drawBackground(_ c: CGContext, size: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(0x1A1F4D), rgb(0x080B1F)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
    let glow1 = CGGradient(colorsSpace: space, colors: [rgb(violet, 0.55), rgb(violet, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow1, startCenter: CGPoint(x: size * 0.22, y: size * 0.12), startRadius: 0, endCenter: CGPoint(x: size * 0.22, y: size * 0.12), endRadius: size * 0.7, options: [])
    let glow2 = CGGradient(colorsSpace: space, colors: [rgb(teal, 0.35), rgb(teal, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow2, startCenter: CGPoint(x: size * 0.9, y: size * 0.95), startRadius: 0, endCenter: CGPoint(x: size * 0.9, y: size * 0.95), endRadius: size * 0.6, options: [])
    // Stars
    var seed: UInt64 = 7
    func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    for _ in 0..<38 {
        let x = rand() * size, y = rand() * size * 0.55, r = (0.6 + rand() * 1.8) * size / 1024
        c.setFillColor(rgb(0xFFFFFF, 0.25 + rand() * 0.5))
        c.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
    }
}

func drawArcs(_ c: CGContext, s: CGFloat, o: CGPoint, mono: CGColor?) {
    // Bifröst: a bridge of light arching over a horizon inside the bubble,
    // stroked with an aurora gradient (violet -> teal -> gold) along its span.
    let center = CGPoint(x: o.x + 512 * s, y: o.y + 622 * s)
    let bands: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [(214, 84, 1), (128, 30, 0.55)]
    for band in bands {
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: band.radius * s, startAngle: .pi, endAngle: 0, clockwise: false)
        let outline = arc.copy(strokingWithWidth: band.width * s, lineCap: .round, lineJoin: .round, miterLimit: 10)
        c.saveGState()
        c.addPath(outline); c.clip()
        if let mono {
            c.setFillColor(mono.copy(alpha: band.alpha)!)
            c.fill(CGRect(x: 0, y: 0, width: 4096, height: 4096))
        } else {
            let g = CGGradient(colorsSpace: space, colors: [rgb(violet, band.alpha), rgb(teal, band.alpha), rgb(gold, band.alpha)] as CFArray, locations: [0.1, 0.5, 0.9])!
            c.drawLinearGradient(g, start: CGPoint(x: center.x - 260 * s, y: center.y - 120 * s), end: CGPoint(x: center.x + 260 * s, y: center.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        c.restoreGState()
    }
    // Horizon star where the bridge lands: Asgard.
    let star = CGPoint(x: center.x, y: center.y - 8 * s)
    c.setFillColor(mono ?? rgb(gold))
    let r: CGFloat = 26 * s
    let p = CGMutablePath()
    p.move(to: CGPoint(x: star.x, y: star.y - r * 1.6))
    p.addQuadCurve(to: CGPoint(x: star.x + r * 1.6, y: star.y), control: CGPoint(x: star.x + r * 0.25, y: star.y - r * 0.25))
    p.addQuadCurve(to: CGPoint(x: star.x, y: star.y + r * 1.6), control: CGPoint(x: star.x + r * 0.25, y: star.y + r * 0.25))
    p.addQuadCurve(to: CGPoint(x: star.x - r * 1.6, y: star.y), control: CGPoint(x: star.x - r * 0.25, y: star.y + r * 0.25))
    p.addQuadCurve(to: CGPoint(x: star.x, y: star.y - r * 1.6), control: CGPoint(x: star.x - r * 0.25, y: star.y - r * 0.25))
    c.addPath(p); c.fillPath()
}

func render(_ v: Variant, size: CGFloat) -> CGImage {
    let c = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1) // top-left origin
    var s = size / 1024, o = CGPoint.zero
    if v == .androidForeground || v == .androidMonochrome || v == .mark {
        // Android adaptive safe zone: keep art within the inner 66%.
        s = size / 1024 * 0.62; o = CGPoint(x: size * 0.19, y: size * 0.18)
    }
    switch v {
    case .light, .androidBackground: drawBackground(c, size: size)
    case .dark: c.setFillColor(rgb(0x05070F)); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
    case .tinted: c.setFillColor(rgb(0x000000)); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
    default: break
    }
    if v == .androidBackground { return c.makeImage()! }

    let bubble = bubblePath(scale: s, offset: o)
    let mono: CGColor? = (v == .tinted || v == .androidMonochrome) ? rgb(0x000000, 1) : nil
    // Soft glow under the bubble
    if v == .light || v == .dark || v == .androidForeground || v == .mark {
        c.saveGState()
        c.setShadow(offset: .zero, blur: 60 * s, color: rgb(violet, 0.6))
        c.addPath(bubble); c.setFillColor(rgb(0xFFFFFF)); c.fillPath()
        c.restoreGState()
    }
    c.saveGState()
    c.addPath(bubble); c.clip()
    switch v {
    case .dark:
        let g = CGGradient(colorsSpace: space, colors: [rgb(0x2A2F63), rgb(0x141838)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: 196 * s), end: CGPoint(x: 0, y: 860 * s), options: [])
    case .tinted, .androidMonochrome:
        c.setFillColor(rgb(0xFFFFFF)); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
    default:
        let g = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xE9E6FF)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: o.y + 196 * s), end: CGPoint(x: 0, y: o.y + 860 * s), options: [])
    }
    c.restoreGState()
    if v == .androidMonochrome {
        c.setBlendMode(.clear)
        drawArcs(c, s: s, o: o, mono: rgb(0, 1))
    } else {
        drawArcs(c, s: s, o: o, mono: mono)
    }
    return c.makeImage()!
}

func write(_ img: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for v in Variant.allCases {
    let size: CGFloat = v.rawValue.hasPrefix("android") ? 432 : 1024
    write(render(v, size: size), to: "\(out)/icon-\(v.rawValue).png")
}
print("rendered \(Variant.allCases.count) variants to \(out)")
