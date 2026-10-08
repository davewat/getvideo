// Draws the GetVideo app icon: a dark macOS tile holding seven broadcast
// colour bars above a three-segment timeline strip.
//
//   swift mac/make-icon.swift icon.png      1024x1024 PNG
//
// mac/AppIcon.icns is built from that PNG (sips at each iconset size, then
// iconutil -c icns); regenerate it whenever this file changes.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create bitmap context")
}
// Work in top-left-origin coordinates, like the design grid.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// The standard macOS icon grid: an 824pt tile centred in the 1024pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(color(0x141C26))
ctx.fillPath()

// Content box, inset evenly from the tile edges.
let inset: CGFloat = 124
let content = tile.insetBy(dx: inset, dy: inset)
let stripHeight: CGFloat = 40
let stripGap: CGFloat = 38

// Seven colour bars, clipped to one slightly rounded block.
let bars: [UInt32] = [0xE9EDF2, 0xE3B505, 0x2BB8CA, 0x3FB56F, 0xD85CB1, 0xEF6A54, 0x6F93F5]
let barArea = CGRect(x: content.minX, y: content.minY, width: content.width,
                     height: content.height - stripHeight - stripGap)
let barWidth = barArea.width / CGFloat(bars.count)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: barArea, cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.clip()
ctx.setShouldAntialias(false) // keep the seams between bars crisp
for (i, hex) in bars.enumerated() {
    let x0 = (barArea.minX + CGFloat(i) * barWidth).rounded()
    let x1 = (barArea.minX + CGFloat(i + 1) * barWidth).rounded()
    ctx.setFillColor(color(hex))
    ctx.fill(CGRect(x: x0, y: barArea.minY, width: x1 - x0, height: barArea.height))
}
ctx.restoreGState()

// Timeline strip: cyan, magenta, then a half-width green segment.
let segments: [(UInt32, CGFloat)] = [(0x2BB8CA, 1), (0xD85CB1, 1), (0x3FB56F, 0.5)]
let gap: CGFloat = 16
let unit = (content.width - gap * CGFloat(segments.count - 1)) / segments.reduce(0) { $0 + $1.1 }
var x = content.minX
for (hex, weight) in segments {
    let rect = CGRect(x: x.rounded(), y: content.maxY - stripHeight, width: (unit * weight).rounded(),
                      height: stripHeight)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(color(hex))
    ctx.fillPath()
    x += unit * weight + gap
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot write \(output.path)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(output.path)") }
print("wrote \(output.path)")
