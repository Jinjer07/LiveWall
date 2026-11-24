// Генерация иконки LiveWall (1024×1024 PNG) на CoreGraphics.
// Запуск: swiftc tools/make_icon.swift -o build/make_icon && build/make_icon assets/icon-1024.png
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let crimson = rgb(0.863, 0.078, 0.235), scarlet = rgb(1, 0.2, 0.25), blood = rgb(0.52, 0.03, 0.11), ember = rgb(1, 0.42, 0.26)

// Подложка-«сквиркл» по сетке macOS (отступ 100, скругление ~185)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0, 0, 0, 0.55))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0.06, 0.06, 0.07)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
// Угольный градиент
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.13, 0.13, 0.15), rgb(0.04, 0.04, 0.05)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// Алое свечение снизу
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0.86, 0.08, 0.24, 0.75), rgb(0.86, 0.08, 0.24, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 300), startRadius: 0, endCenter: CGPoint(x: 512, y: 300), endRadius: 520, options: [])
// Угольки
srand48(7)
for _ in 0..<46 {
    let x = 140 + drand48() * 744, y = 130 + drand48() * 420, r = 2 + drand48() * 6
    let a = 0.25 + drand48() * 0.6
    let g = CGGradient(colorsSpace: cs, colors: [rgb(1, 0.45, 0.3, a), rgb(1, 0.2, 0.25, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r * 3, options: [])
}
// Тонкая внутренняя обводка
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(1, 1, 1, 0.08)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// Три слоя-рамки
let w: CGFloat = 470, h: CGFloat = 340, r: CGFloat = 70, lw: CGFloat = 26
func frameRect(_ dx: CGFloat, _ dy: CGFloat) -> CGRect { CGRect(x: 512 - w / 2 + dx, y: 512 - h / 2 + dy, width: w, height: h) }
ctx.setLineWidth(lw); ctx.setLineCap(.round)
ctx.addPath(CGPath(roundedRect: frameRect(80, 80), cornerWidth: r, cornerHeight: r, transform: nil))
ctx.setStrokeColor(rgb(0.86, 0.08, 0.24, 0.38)); ctx.strokePath()
ctx.addPath(CGPath(roundedRect: frameRect(40, 40), cornerWidth: r, cornerHeight: r, transform: nil))
ctx.setStrokeColor(rgb(1, 0.2, 0.25, 0.7)); ctx.strokePath()

// Передняя плашка с градиентом и свечением
let front = frameRect(-10, -10)
let frontPath = CGPath(roundedRect: front, cornerWidth: r, cornerHeight: r, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0.86, 0.08, 0.24, 0.85))
ctx.addPath(frontPath); ctx.setFillColor(crimson); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(frontPath); ctx.clip()
let fg = CGGradient(colorsSpace: cs, colors: [scarlet, crimson, blood] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(fg, start: CGPoint(x: front.minX, y: front.maxY), end: CGPoint(x: front.maxX, y: front.minY), options: [])
let shine = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: front.maxY), end: CGPoint(x: 0, y: front.midY), options: [])
ctx.restoreGState()

// Волна
let wave = CGMutablePath()
let ww = w * 0.62, wh = h * 0.42, ox = front.midX - ww / 2, oy = front.midY
for i in 0...80 {
    let t = CGFloat(i) / 80
    let p = CGPoint(x: ox + ww * t, y: oy - sin(t * .pi * 2.4) * wh * 0.5 * (0.4 + 0.6 * t))
    if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: rgb(1, 1, 1, 0.6))
ctx.addPath(wave); ctx.setStrokeColor(rgb(1, 1, 1, 0.97)); ctx.setLineWidth(24); ctx.setLineJoin(.round); ctx.strokePath()
ctx.restoreGState()
_ = ember

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok \(out)")
