// Draws the app icon: the Creator Micro 2 itself, keys lit the way the app
// lights them. Run by bundle.sh at build time — the icon is generated, not a
// checked-in binary.
//
//   swift scripts/genicon.swift <output.iconset>
//
// Emits the ten PNGs `iconutil -c icns` expects.

import AppKit

let canvas: CGFloat = 1024

func rgb(_ packed: Int) -> NSColor {
    NSColor(
        srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
        green: CGFloat((packed >> 8) & 0xFF) / 255,
        blue: CGFloat(packed & 0xFF) / 255,
        alpha: 1
    )
}

/// One cell of the icon's grid: a key lit with a colour, an unlit key, or a
/// rotary knob.
enum Cell {
    case key(Int)
    case dark
    case knob
    case empty
}

// The pad as the app presents it: agent statuses across the top six keys,
// then the stack, tab-cycle and land keys in their own colours. Row order is
// top to bottom as you look at the device.
let grid: [[Cell]] = [
    [.key(0x00C853), .key(0xFFA000), .knob, .knob],
    [.key(0x00B0FF), .key(0x00C853), .key(0xFFA000), .key(0xFF2D2D)],
    [.key(0x7C4DFF), .key(0x00BFA5), .dark, .key(0xE91E63)],
    [.empty, .dark, .dark, .dark],
]

func draw(in ctx: CGContext) {
    // Standard macOS icon geometry: an 832pt rounded rect centred on a 1024pt
    // transparent canvas.
    let body = CGRect(x: 96, y: 96, width: 832, height: 832)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x191C23).cgColor)
    ctx.fillPath()

    let gap: CGFloat = 30
    let inset: CGFloat = 104
    let key = (body.width - inset * 2 - gap * 3) / 4   // 4 columns
    let radius: CGFloat = 30

    for (rowIndex, row) in grid.enumerated() {
        let y = body.maxY - inset - key - CGFloat(rowIndex) * (key + gap)
        for (column, cell) in row.enumerated() {
            let x = body.minX + inset + CGFloat(column) * (key + gap)
            let frame = CGRect(x: x, y: y, width: key, height: key)
            switch cell {
            case .key(let packed):
                ctx.addPath(CGPath(
                    roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil
                ))
                ctx.setFillColor(rgb(packed).cgColor)
                ctx.fillPath()
            case .dark:
                ctx.addPath(CGPath(
                    roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil
                ))
                ctx.setFillColor(rgb(0x2A2F3A).cgColor)
                ctx.fillPath()
            case .knob:
                ctx.addEllipse(in: frame.insetBy(dx: 6, dy: 6))
                ctx.setFillColor(rgb(0x2A2F3A).cgColor)
                ctx.fillPath()
                ctx.addEllipse(in: frame.insetBy(dx: 6, dy: 6))
                ctx.setStrokeColor(rgb(0x3C4350).cgColor)
                ctx.setLineWidth(8)
                ctx.strokePath()
                // Indicator dot at twelve o'clock.
                let dot = CGRect(
                    x: frame.midX - 10, y: frame.maxY - 40, width: 20, height: 20
                )
                ctx.addEllipse(in: dot)
                ctx.setFillColor(rgb(0x5C6270).cgColor)
                ctx.fillPath()
            case .empty:
                break
            }
        }
    }
}

func writePNG(size: Int, scale: Int, to url: URL) {
    let pixels = size * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not make bitmap \(pixels)px") }

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: genicon.swift <output.iconset>\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    writePNG(size: size, scale: 1, to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    writePNG(size: size, scale: 2, to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
