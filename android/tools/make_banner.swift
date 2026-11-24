// Tạo banner 320x180 (xhdpi) cho Android TV launcher: nền gradient + biểu tượng TV + chữ "Beamly".
import AppKit

let W = 320, H = 180
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(red: 0.31, green: 0.48, blue: 1.0, alpha: 1),
           ending: NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)

let cfg = NSImage.SymbolConfiguration(pointSize: 62, weight: .semibold).applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "play.tv", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white]
let text = "Beamly" as NSString
let ts = text.size(withAttributes: attrs)
let gap: CGFloat = 14
let total = sym.size.width + gap + ts.width
let x0 = (CGFloat(W) - total) / 2
sym.draw(in: NSRect(x: x0, y: (CGFloat(H) - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
text.draw(at: NSPoint(x: x0 + sym.size.width + gap, y: (CGFloat(H) - ts.height) / 2), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
