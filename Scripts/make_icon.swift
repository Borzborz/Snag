import AppKit

// Usage: swift make_icon.swift <output.png>  — draws the 1024px app icon.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
let colors = [CGColor(srgbRed: 0.30, green: 0.36, blue: 0.98, alpha: 1),
              CGColor(srgbRed: 0.72, green: 0.28, blue: 0.95, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                       end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
ctx.restoreGState()

// Viewfinder corners
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let frame = plate.insetBy(dx: 200, dy: 200)
let arm: CGFloat = 130
for (cx, cy, sx, sy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                         (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: cx + arm * sx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy + arm * sy))
    ctx.strokePath()
}
// Centre crosshair
ctx.setLineWidth(44)
ctx.strokeLineSegments(between: [CGPoint(x: 512 - 70, y: 512), CGPoint(x: 512 + 70, y: 512),
                                 CGPoint(x: 512, y: 512 - 70), CGPoint(x: 512, y: 512 + 70)])

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
