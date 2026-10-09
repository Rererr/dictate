import AppKit

// Dictate のアプリアイコン。押し込まれたバックライト付きのキーの上に、光るマイクの線画。
// 「押している間だけ話す」を、押されている最中のキーで表す。
// 1024 を基準に描き、各サイズは同じ形を縮小して描く。出力は build/AppIcon.icns と確認用の PNG。
// macOS 26 以降専用なので、全面に描いて角丸はシステムの切り抜きに任せる。

let canvas: CGFloat = 1024
let stroke: CGFloat = 50
/// キーの面に対するマイクの大きさと、縦の伸び。受け皿（U 字）は底を支点に少し短くする。
let glyphScale: CGFloat = 0.82
let stretch: CGFloat = 1.20
let cradleScale: CGFloat = 0.95
let glyphCenter = CGPoint(x: 512, y: 535)
/// 台座があるぶん重心が下がるので、キーの面に対して光学的に中央に見える高さまで上げる。
let opticalLift: CGFloat = 19

let colorSpace = CGColorSpaceCreateDeviceRGB()

func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawBackground(_ ctx: CGContext) {
    ctx.drawLinearGradient(
        gradient([rgba(0.015, 0.035, 0.085), rgba(0.055, 0.075, 0.16)], [0, 1]),
        start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: canvas), options: []
    )
}

/// 押し込まれたキー。側面は薄く、上縁と左縁に周囲から落ちる影、面にはマイクの光が広がる。
func drawKey(_ ctx: CGContext) {
    let radius: CGFloat = 118
    ctx.addPath(roundedRect(CGRect(x: 170, y: 166, width: 684, height: 700), radius))
    ctx.setFillColor(rgba(0.045, 0.065, 0.105))
    ctx.fillPath()

    let face = roundedRect(CGRect(x: 170, y: 190, width: 684, height: 700), radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 28, height: -40), blur: 36, color: rgba(0, 0, 0, 0.30))
    ctx.addPath(face)
    ctx.setFillColor(rgba(0.12, 0.15, 0.20))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(face)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgba(0.19, 0.22, 0.27), rgba(0.12, 0.15, 0.20)], [0, 1]),
        start: CGPoint(x: 215, y: 865), end: CGPoint(x: 820, y: 205), options: []
    )
    let cavity = gradient([rgba(0, 0, 0, 0.28), rgba(0, 0, 0, 0)], [0, 1])
    ctx.drawLinearGradient(cavity, start: CGPoint(x: 512, y: 890), end: CGPoint(x: 512, y: 800), options: [])
    ctx.drawLinearGradient(cavity, start: CGPoint(x: 170, y: 540), end: CGPoint(x: 230, y: 540), options: [])
    let spill = gradient([rgba(0.10, 0.82, 1, 0.34), rgba(0.10, 0.82, 1, 0.10), rgba(0.10, 0.82, 1, 0)], [0, 0.4, 1])
    let spillCenter = CGPoint(x: 512, y: 560)
    ctx.drawRadialGradient(spill, startCenter: spillCenter, startRadius: 0, endCenter: spillCenter, endRadius: 400, options: [])
    ctx.restoreGState()

    ctx.addPath(face)
    ctx.setStrokeColor(rgba(0.40, 0.55, 0.64, 0.8))
    ctx.setLineWidth(5)
    ctx.strokePath()
}

/// マイク。カプセルは線幅の枠だけで、内側は重なる受け皿と支柱ごとくり抜く。
/// 各部は同じ色で重ねて塗り、発光は透明レイヤーにまとめて一度だけ掛ける（継ぎ目が出ない）。
func drawMicrophone(_ ctx: CGContext) {
    let y: (CGFloat) -> CGFloat = { glyphCenter.y + ($0 - glyphCenter.y) * stretch }
    let cradlePivot = y(460)
    let cradleY: (CGFloat) -> CGFloat = { cradlePivot + (y($0) - cradlePivot) * cradleScale }

    let capsuleRect = CGRect(x: 428, y: y(420), width: 168, height: y(770) - y(420))
    let capsule = roundedRect(capsuleRect, 84)
    let capsuleInner = roundedRect(capsuleRect.insetBy(dx: stroke, dy: stroke), 84 - stroke)

    let cradle = CGMutablePath()
    cradle.move(to: CGPoint(x: 330, y: cradleY(590)))
    cradle.addLine(to: CGPoint(x: 330, y: cradleY(510)))
    cradle.addCurve(to: CGPoint(x: 694, y: cradleY(510)), control1: CGPoint(x: 330, y: cradleY(410)), control2: CGPoint(x: 694, y: cradleY(410)))
    cradle.addLine(to: CGPoint(x: 694, y: cradleY(590)))

    let stem = roundedRect(CGRect(x: 487, y: y(300) - stroke / 2, width: stroke, height: y(420) - y(300) + stroke), stroke / 2)
    let base = roundedRect(CGRect(x: 375, y: y(300) - stroke / 2, width: 274, height: stroke), stroke / 2)

    ctx.saveGState()
    ctx.translateBy(x: glyphCenter.x * (1 - glyphScale), y: glyphCenter.y * (1 - glyphScale) + opticalLift)
    ctx.scaleBy(x: glyphScale, y: glyphScale)
    ctx.addRect(CGRect(x: -canvas, y: -canvas, width: canvas * 3, height: canvas * 3))
    ctx.addPath(capsuleInner)
    ctx.clip(using: .evenOdd)

    ctx.setShadow(offset: .zero, blur: 22, color: rgba(0.10, 0.82, 1, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let ink = rgba(0.70, 0.97, 1)
    ctx.setFillColor(ink)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(cradle)
    ctx.strokePath()
    for part in [capsule, stem, base] {
        ctx.addPath(part)
        ctx.fillPath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func renderPNG(pixelSize: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: pixelSize * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "DictateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "描画コンテキストを作れません（\(pixelSize)px）"])
    }
    ctx.scaleBy(x: CGFloat(pixelSize) / canvas, y: CGFloat(pixelSize) / canvas)
    drawBackground(ctx)
    drawKey(ctx)
    drawMicrophone(ctx)
    guard let image = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DictateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG にできません（\(pixelSize)px）"])
    }
    try data.write(to: url)
}

let build = URL(fileURLWithPath: "build", isDirectory: true)
let iconset = build.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try renderPNG(pixelSize: size * scale, to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
try renderPNG(pixelSize: 1024, to: build.appendingPathComponent("icon-preview-1024.png"))
try renderPNG(pixelSize: 32, to: build.appendingPathComponent("icon-preview-32.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", build.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "DictateIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil が \(iconutil.terminationStatus) で終了しました"])
}
