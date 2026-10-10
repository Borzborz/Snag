import AppKit

/// Builds the editor screenshot shown in the README: a made-up dashboard with a few marks on it.
/// Nothing from the real capture library appears in the picture and nothing is saved to it.
enum DemoShot {
    static func run(output: URL) {
        _ = NSApplication.shared
        let controller = EditorController()
        let doc = document(url: output)
        controller.canvas.doc = doc
        controller.currentURL = doc.url
        let finished = doc.render(outside: .expandWhite)
        controller.items = [LibraryItem(url: doc.url, thumb: NSImage(cgImage: finished, size: NSSize(width: 160, height: 100)))]
        controller.tool = .callout

        let window = controller.window
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1320, height: 960))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.zoomToFit()

        // Click the callout so the picture shows a selected mark and its style panel.
        if let callout = doc.annotations.first(where: { $0.tool == .callout }) {
            let inCanvas = controller.canvas.viewPoint(CGPoint(x: callout.boxRect.midX, y: callout.boxRect.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: controller.canvas.convert(inCanvas, to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { controller.canvas.mouseDown(with: event) } else { controller.canvas.mouseUp(with: event) }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The snapshot leaves the window's own backdrop out, so lay it over one, with rounded corners.
        let frame = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let snapshot = rep.cgImage,
              let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
        ctx.fill(frame)
        ctx.draw(snapshot, in: frame)
        if let image = ctx.makeImage() { Library.write(image, scale: 2, to: output) }
    }

    private static func document(url: URL) -> CaptureDocument {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let blue = NSColor(srgbRed: 0.24, green: 0.48, blue: 0.95, alpha: 1)
        let dark = NSColor(white: 0.15, alpha: 1), grey = NSColor(white: 0.5, alpha: 1)
        func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        @discardableResult
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor = dark) -> CGRect {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                             .foregroundColor: color]
            (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            return CGRect(origin: CGPoint(x: x, y: y), size: (string as NSString).size(withAttributes: attributes))
        }

        fill(CGRect(x: 0, y: 0, width: w, height: h), .white)
        fill(CGRect(x: 0, y: 0, width: w, height: 88), NSColor(white: 0.93, alpha: 1))
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(CGRect(x: 28 + i * 36, y: 33, width: 22, height: 22), color.withAlphaComponent(0.8), radius: 11)
        }
        text("Dashboard — Q3 report", x: 650, y: 26, size: 30, weight: .medium, color: grey)

        fill(CGRect(x: 0, y: 88, width: 300, height: h - 88), NSColor(white: 0.965, alpha: 1))
        fill(CGRect(x: 20, y: 208, width: 200, height: 62), blue.withAlphaComponent(0.14), radius: 12)
        for (i, name) in ["Overview", "Sales", "Customers", "Invoices", "Settings"].enumerated() {
            text(name, x: 44, y: CGFloat(148 + i * 72), size: 30, weight: i == 1 ? .semibold : .regular,
                 color: i == 1 ? blue : dark)
        }

        text("Revenue", x: 360, y: 124, size: 54, weight: .bold)
        let updated = text("Updated today · Owner: ", x: 360, y: 204, size: 26, color: grey)
        let email = text("jordan@example.com", x: updated.maxX, y: 204, size: 26, color: grey)
        let button = CGRect(x: 1350, y: 128, width: 190, height: 64)
        fill(button, blue, radius: 12)
        text("Export", x: button.minX + 52, y: button.minY + 14, size: 28, weight: .semibold, color: .white)

        fill(CGRect(x: 370, y: 740, width: 830, height: 2), NSColor(white: 0.8, alpha: 1))
        let months = ["Apr", "May", "Jun", "Jul", "Aug", "Sep"]
        var tallest = CGRect.zero
        for (i, height) in [180, 240, 210, 300, 400, 330].enumerated() {
            let bar = CGRect(x: 400 + i * 130, y: 740 - height, width: 84, height: height)
            fill(bar, blue.withAlphaComponent(i == 4 ? 1 : 0.55), radius: 6)
            if i == 4 { tallest = bar }
            text(months[i], x: bar.minX + 18, y: 754, size: 24, color: grey)
        }
        let total = text("Total: $48,200", x: 360, y: 850, size: 34, weight: .semibold)
        let growth = text("Growth: +12%", x: total.maxX + 60, y: 850, size: 34, weight: .semibold)
        NSGraphicsContext.current = nil

        let doc = CaptureDocument(base: ctx.makeImage()!, scale: 2, url: url)
        func make(_ tool: Tool, _ a: CGPoint, _ b: CGPoint = .zero, text: String = "",
                  style change: (inout Style) -> Void = { _ in }) -> Annotation {
            var style = Style.standard(for: tool)
            change(&style)
            var annotation = Annotation(tool: tool, at: a, style: style, scale: 2)
            annotation.end = b
            annotation.text = text
            return annotation
        }

        let highlight = growth.insetBy(dx: -10, dy: -4)
        doc.annotations.append(make(.highlight, highlight.origin, CGPoint(x: highlight.maxX, y: highlight.maxY)))
        let hidden = email.insetBy(dx: -6, dy: -4)
        doc.annotations.append(make(.blur, hidden.origin, CGPoint(x: hidden.maxX, y: hidden.maxY)))
        for i in 0..<3 {
            var step = make(.step, CGPoint(x: 254, y: CGFloat(166 + i * 72))) { $0.width = 2 }
            step.number = i + 1
            doc.annotations.append(step)
        }

        // A box round the button, with a callout snapped to its bottom edge.
        let frame = button.insetBy(dx: -14, dy: -14)
        let box = make(.rect, frame.origin, CGPoint(x: frame.maxX, y: frame.maxY))
        doc.annotations.append(box)
        var callout = make(.callout, CGPoint(x: 1090, y: 330), CGPoint(x: frame.midX, y: frame.maxY),
                           text: "Export as PDF or PNG") { $0.fontSize = 18 }
        callout.endLink = box.link(at: callout.end)

        // A label with an arrow snapped to it, pointing at the tallest bar.
        let label = make(.text, CGPoint(x: 560, y: 270), text: "Best month") {
            ($0.fontSize, $0.fill, $0.stroke, $0.text) = (18, EditorController.palette[4], nil, .paper)
        }
        var arrow = make(.arrow, CGPoint(x: label.boxRect.maxX, y: label.boxRect.midY),
                         CGPoint(x: tallest.minX - 6, y: tallest.minY + 10)) {
            ($0.fill, $0.stroke) = (Style.yellow, .ink)
        }
        arrow.startLink = label.link(at: arrow.start)
        doc.annotations += [label, arrow, callout]
        doc.resolveLinks()
        return doc
    }
}
