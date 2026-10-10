import AppKit

/// Renders one of every annotation onto a synthetic image, for checking drawing code without a screen.
enum RenderTest {
    /// Snapshots the editor window offscreen after clicking the callout with the Box tool active.
    static func ui(output: URL) {
        _ = NSApplication.shared
        let controller = EditorController()
        let doc = sampleDocument(url: output)
        controller.canvas.doc = doc
        controller.currentURL = doc.url
        controller.tool = .rect
        let window = controller.window
        window.appearance = NSAppearance(named: .aqua) // the snapshot has no window backdrop
        window.setContentSize(NSSize(width: 1040, height: 920))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.zoomToFit()

        func click(_ type: NSEvent.EventType, _ imagePoint: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            let inCanvas = controller.canvas.viewPoint(imagePoint)
            return NSEvent.mouseEvent(with: type, location: controller.canvas.convert(inCanvas, to: nil),
                                      modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ flags: NSEvent.ModifierFlags = []) {
            let event = click(type, CGPoint(x: x, y: y), flags)
            switch type {
            case .leftMouseDown: controller.canvas.mouseDown(with: event)
            case .leftMouseDragged: controller.canvas.mouseDragged(with: event)
            case .leftMouseUp: controller.canvas.mouseUp(with: event)
            default: controller.canvas.mouseMoved(with: event)
            }
        }
        func drag(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, flags: NSEvent.ModifierFlags = []) {
            send(.leftMouseDown, x0, y0, flags)
            send(.leftMouseDragged, (x0 + x1) / 2, (y0 + y1) / 2, flags)
            send(.leftMouseDragged, x1, y1, flags)
            send(.leftMouseUp, x1, y1, flags)
        }
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.01 }
        // All with the Box tool active.
        let count = doc.annotations.count
        drag(770, 150, 650, 270) // red arrow, grabbed by its shaft
        print("arrow moved:", doc.annotations[0].start == CGPoint(x: 780, y: 200))
        drag(300, 225, 300, 255) // highlight, grabbed by its middle
        print("highlight moved:", doc.annotations[6].start.y == 230)
        drag(200, 60, 300, 78) // inside the unselected red box: must draw, not grab
        print("drew inside unselected box:", doc.annotations.count == count + 1)
        controller.canvas.undo(nil)
        drag(50, 60, 80, 60) // red box by its left edge, which also selects it
        drag(200, 60, 230, 60) // now selected, so its inside grabs
        print("selected box moved by its inside:", doc.annotations[4].start.x == 110, doc.annotations.count == count)
        drag(640, 400, 760, 440) // draw a new box: it should stay selected
        print("new box selected:", controller.hasSelection, controller.styleTool == .rect)
        // Text box "Text box" sits at (560, 470): grab it, then drag its corner grip to double the type.
        drag(600, 490, 600, 490)
        let textIndex = doc.annotations.firstIndex { $0.text == "Text box" }!
        let before = doc.annotations[textIndex]
        let grip = CGPoint(x: before.boxRect.maxX, y: before.boxRect.maxY)
        drag(grip.x, grip.y, before.boxRect.minX + before.boxRect.width * 1.5, grip.y)
        print("text resized by grip:", before.fontSize, "->", doc.annotations[textIndex].fontSize,
              "panel shows", controller.style.fontSize)
        controller.updateStyle { $0.fontFamily = "Georgia" }
        print("font applied to selection:", doc.annotations[textIndex].fontFamily)
        // Drag the text box's right side out: it gets a set width; then its bottom side down.
        let sizedBefore = doc.annotations[textIndex]
        drag(sizedBefore.boxRect.maxX, sizedBefore.boxRect.midY, sizedBefore.boxRect.maxX + 150, sizedBefore.boxRect.midY)
        let widened = doc.annotations[textIndex]
        drag(widened.boxRect.midX, widened.boxRect.maxY, widened.boxRect.midX, widened.boxRect.maxY + 60)
        let tall = doc.annotations[textIndex]
        print("box widened by its side:", sizedBefore.boxRect.width, "->", tall.boxRect.width,
              "| heightened:", sizedBefore.boxRect.height, "->", tall.boxRect.height)
        controller.updateStyle { ($0.hAlign, $0.vAlign) = (.right, .bottom) }
        print("alignment applied:", doc.annotations[textIndex].hAlign, doc.annotations[textIndex].vAlign)
        // Put a callout down, type nothing, switch tool: it must stay.
        controller.tool = .callout
        let beforeCallout = doc.annotations.count
        drag(330, 640, 180, 700)
        controller.tool = .rect
        print("empty callout kept after switching tool:", doc.annotations.count == beforeCallout + 1,
              doc.annotations.last?.tool == .callout)
        drag(600, 490, 600, 490) // reselect the text box
        controller.updateStyle { $0.borderWidth = 9 }
        print("border size applied to selection:", doc.annotations[textIndex].borderWidth / doc.scale, "pt")
        // The yellow arrow (index 1) has a black outline: select it and thicken only the outline.
        drag(1050, 120, 1050, 120)
        let bodyBefore = doc.annotations[1].lineWidth
        controller.updateStyle { $0.borderWidth = 6 }
        print("arrow outline:", doc.annotations[1].borderWidth / doc.scale, "pt, body unchanged:",
              doc.annotations[1].lineWidth == bodyBefore)
        // Drag the callout's box out past the right edge: the canvas should grow to hold it.
        let calloutIndex = doc.annotations.firstIndex { $0.text == "Callout" }!
        let frameBefore = controller.canvas.frame.size
        drag(860, 540, 1010, 540)
        drag(1010, 540, 1160, 540)
        print("callout box now ends at x =", doc.annotations[calloutIndex].boxRect.maxX, "(image is 1200 wide)")
        print("canvas grew:", frameBefore, "->", controller.canvas.frame.size)
        // Snapping: draw an arrow that ends near the callout's left side; it should land exactly on
        // the side's midpoint and be fastened there.
        let calloutID = doc.annotations[calloutIndex].id
        var box = doc.annotations[calloutIndex].boxRect
        var side = CGPoint(x: box.minX, y: box.midY)
        controller.tool = .arrow
        drag(side.x - 220, side.y + 160, side.x - 7, side.y + 6)
        let arrowIndex = doc.annotations.count - 1
        var arrow: Annotation { doc.annotations[arrowIndex] }
        print("arrow end snapped to callout side:", close(arrow.end, side),
              "| fastened:", arrow.endLink?.target == calloutID, controller.canUnsnap)
        // Move the callout by its box: the snapped arrow comes along whole.
        drag(box.midX, box.midY, box.midX - 60, box.midY + 40)
        print("snapped arrow moved with the callout:", close(arrow.end, CGPoint(x: side.x - 60, y: side.y + 40)),
              close(arrow.start, CGPoint(x: side.x - 280, y: side.y + 200)))
        // Move the arrow by its shaft: the callout comes along too.
        let boxBefore = doc.annotations[calloutIndex].boxRect
        let mid = CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
        drag(mid.x, mid.y, mid.x + 20, mid.y - 10)
        box = doc.annotations[calloutIndex].boxRect
        side = CGPoint(x: box.minX, y: box.midY)
        print("callout moved with the snapped arrow:", close(box.origin, CGPoint(x: boxBefore.minX + 20, y: boxBefore.minY - 10)),
              close(arrow.end, side))
        // ⌥-drag moves the callout alone: the arrow's snapped end follows, its other end stays.
        var startBefore = arrow.start
        drag(box.midX, box.midY, box.midX + 30, box.midY - 20, flags: .option)
        box = doc.annotations[calloutIndex].boxRect
        side = CGPoint(x: box.minX, y: box.midY)
        print("option-drag moved the callout alone, arrow stretched:", arrow.start == startBefore, close(arrow.end, side))
        // Widen the callout by its left side: the snapped end stays on that side's middle.
        drag(side.x, side.y, side.x - 50, side.y)
        box = doc.annotations[calloutIndex].boxRect
        print("snapped end followed the resized box:", box.minX < side.x - 40, close(arrow.end, CGPoint(x: box.minX, y: box.midY)))
        side = CGPoint(x: box.minX, y: box.midY)
        // Unsnap, then move the callout: the arrow stays where it was. Snap fastens it again.
        controller.unsnapSelection()
        startBefore = arrow.start
        drag(box.midX, box.midY, box.midX, box.midY + 30)
        print("unsnapped arrow stayed put:", arrow.endLink == nil, arrow.start == startBefore, close(arrow.end, side),
              "| can snap:", controller.canSnap, "can unsnap:", controller.canUnsnap)
        drag(box.midX, box.midY + 30, box.midX, box.midY)
        print("touching again, can snap:", controller.canSnap)
        controller.snapSelection()
        print("snapped again:", arrow.endLink?.target == calloutID, controller.canUnsnap)
        // Dragging the snapped end away from the box unsnaps it.
        let shaft = CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
        drag(shaft.x, shaft.y, shaft.x, shaft.y) // select the arrow
        drag(arrow.end.x, arrow.end.y, side.x - 60, side.y + 190)
        print("dragging the end off unsnapped it:", arrow.endLink == nil, close(arrow.end, CGPoint(x: side.x - 60, y: side.y + 190)),
              "| callout no longer snapped:", !doc.isSnapped(calloutID))
        drag(arrow.end.x, arrow.end.y, side.x + 5, side.y - 4)
        print("dropping it back snapped it:", arrow.endLink?.target == calloutID, close(arrow.end, side))
        controller.snapEnabled = false
        let marksBefore = doc.annotations.count
        drag(side.x - 300, side.y + 260, side.x - 7, side.y + 6)
        print("no snap when switched off:", doc.annotations.count == marksBefore + 1,
              doc.annotations.last!.end == CGPoint(x: side.x - 7, y: side.y + 6), doc.annotations.last!.endLink == nil)
        controller.snapEnabled = true
        // Pasting marks copied from a 1x capture into this 2x one doubles their geometry, and an
        // arrow snapped to a box in the copy stays snapped to the pasted box, not the original.
        var foreign = Annotation(tool: .rect, at: CGPoint(x: 40, y: 300), style: .standard(for: .rect), scale: 1)
        foreign.end = CGPoint(x: 90, y: 330)
        var pointer = Annotation(tool: .arrow, at: CGPoint(x: 10, y: 360), style: .standard(for: .arrow), scale: 1)
        pointer.end = CGPoint(x: 40, y: 315)
        pointer.endLink = foreign.link(at: pointer.end)
        let beforePaste = doc.annotations.count
        controller.canvas.paste(marks: [foreign, pointer], sourceScale: 1, at: nil)
        let pastedBox = doc.annotations[beforePaste], pastedArrow = doc.annotations[beforePaste + 1]
        print("pasted marks added and rescaled:", doc.annotations.count == beforePaste + 2, pastedBox.rect.size,
              "| still snapped to each other:", pastedArrow.endLink?.target == pastedBox.id, pastedBox.id != foreign.id,
              close(pastedArrow.end, CGPoint(x: pastedBox.rect.minX, y: pastedBox.rect.midY)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output)
    }

    static func run(output: URL) {
        let doc = sampleDocument(url: output)
        // A callout hanging off the right edge and a multi-line serif box off the bottom:
        // the picture should grow white space on those two sides only.
        var style = Style.standard(for: .callout)
        var off = Annotation(tool: .callout, at: CGPoint(x: 1120, y: 250), style: style, scale: 2)
        off.end = CGPoint(x: 1080, y: 420)
        off.text = "Past the edge"
        doc.annotations.append(off)
        (style.fontFamily, style.fontSize, style.bold) = ("Georgia", 30, false)
        var serif = Annotation(tool: .text, at: CGPoint(x: 200, y: 700), style: style, scale: 2)
        serif.text = "Georgia 30, regular\nsecond line"
        doc.annotations.append(serif)
        // A callout with a set width and height: text wraps, sits centred and at the bottom.
        var sized = Annotation(tool: .callout, at: CGPoint(x: 60, y: 440), style: .standard(for: .callout), scale: 2)
        sized.end = CGPoint(x: 420, y: 330)
        sized.text = "A wider callout whose words wrap inside a box that was dragged to this size"
        (sized.boxWidth, sized.boxHeight, sized.hAlign, sized.vAlign) = (360, 230, .center, .bottom)
        doc.annotations.append(sized)
        var empty = Annotation(tool: .callout, at: CGPoint(x: 900, y: 500), style: .standard(for: .callout), scale: 2)
        empty.end = CGPoint(x: 1000, y: 620)
        doc.annotations.append(empty)
        // An arrow snapped to the oval's right side.
        var snappedArrow = Annotation(tool: .arrow, at: CGPoint(x: 1190, y: 300), style: .standard(for: .arrow), scale: 2)
        snappedArrow.end = CGPoint(x: 1140, y: 380)
        snappedArrow.endLink = doc.annotations[5].link(at: snappedArrow.end)
        doc.annotations.append(snappedArrow)

        // Marks must survive a save and reload unchanged.
        let probe = URL(fileURLWithPath: "/tmp/snag-roundtrip-test.png")
        EditStore.save(base: doc.base, annotations: doc.annotations, scale: 2, for: probe)
        let loaded = EditStore.load(for: probe)
        EditStore.remove(for: probe)
        let same = loaded.map { edits in
            edits.annotations.count == doc.annotations.count && zip(edits.annotations, doc.annotations).allSatisfy {
                $0.tool == $1.tool && $0.start == $1.start && $0.end == $1.end && $0.points == $1.points
                    && $0.fill == $1.fill && $0.stroke == $1.stroke && $0.textColor == $1.textColor
                    && $0.text == $1.text && $0.fontFamily == $1.fontFamily && $0.fontSize == $1.fontSize
                    && $0.boxWidth == $1.boxWidth && $0.vAlign == $1.vAlign && $0.borderWidth == $1.borderWidth
                    && $0.id == $1.id && $0.startLink == $1.startLink && $0.endLink == $1.endLink
            } && edits.base.width == doc.base.width
        } ?? false
        print("marks survive save and reload:", same, "(\(doc.annotations.count) marks)")
        print("image", doc.imageRect, "-> picture", doc.contentRect(.expandWhite), "clip:", doc.contentRect(.clip))
        Library.write(doc.render(outside: .expandWhite), scale: 2, to: output)
    }

    private static func sampleDocument(url output: URL) -> CaptureDocument {
        let w = 1200, h = 760
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for row in 0..<12 {
            ("Sample line \(row + 1): the quick brown fox jumps over the lazy dog" as NSString)
                .draw(at: CGPoint(x: 60, y: 60 + row * 54),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.darkGray])
        }
        NSGraphicsContext.current = nil

        let doc = CaptureDocument(base: ctx.makeImage()!, scale: 2, url: output)
        let palette = EditorController.palette
        func make(_ tool: Tool, _ a: CGPoint, _ b: CGPoint, fill: NSColor? = nil, stroke: NSColor? = nil,
                  text: String = "") -> Annotation {
            var style = Style.standard(for: tool)
            if fill != nil || stroke != nil { (style.fill, style.stroke) = (fill, stroke) }
            var annotation = Annotation(tool: tool, at: a, style: style, scale: 2)
            annotation.end = b
            annotation.text = text
            return annotation
        }
        doc.annotations.append(make(.arrow, CGPoint(x: 900, y: 80), CGPoint(x: 640, y: 220)))
        doc.annotations.append(make(.arrow, CGPoint(x: 1150, y: 40), CGPoint(x: 950, y: 200), fill: palette[2], stroke: .ink))
        doc.annotations.append(make(.arrow, CGPoint(x: 1150, y: 180), CGPoint(x: 1000, y: 280), stroke: palette[4]))
        doc.annotations.append(make(.line, CGPoint(x: 60, y: 690), CGPoint(x: 500, y: 690), fill: palette[4], stroke: .paper))
        doc.annotations.append(make(.rect, CGPoint(x: 50, y: 30), CGPoint(x: 420, y: 100)))
        doc.annotations.append(make(.ellipse, CGPoint(x: 860, y: 320), CGPoint(x: 1140, y: 440), fill: palette[3], stroke: .ink))
        doc.annotations.append(make(.highlight, CGPoint(x: 55, y: 200), CGPoint(x: 600, y: 250)))
        doc.annotations.append(make(.blur, CGPoint(x: 55, y: 300), CGPoint(x: 620, y: 420)))
        var pen = make(.pen, .zero, .zero, stroke: palette[5])
        pen.points = stride(from: 0.0, to: 400.0, by: 8).map { CGPoint(x: 700 + $0, y: 660 + sin($0 / 30) * 40) }
        doc.annotations.append(pen)
        doc.annotations.append(make(.text, CGPoint(x: 560, y: 470), .zero, text: "Text box"))
        doc.annotations.append(make(.text, CGPoint(x: 560, y: 560), .zero, fill: palette[4], text: "Fill only"))
        doc.annotations.append(make(.callout, CGPoint(x: 820, y: 520), CGPoint(x: 700, y: 330), text: "Callout"))
        var plain = make(.text, CGPoint(x: 880, y: 590), .zero, text: "No box")
        (plain.fill, plain.stroke, plain.textColor) = (nil, nil, palette[0])
        doc.annotations.append(plain)
        for (i, x) in [100.0, 200.0, 300.0].enumerated() {
            var step = make(.step, CGPoint(x: x, y: 560), .zero)
            step.number = i + 1
            if i == 2 { (step.fill, step.stroke, step.textColor) = (.paper, palette[0], palette[0]) }
            doc.annotations.append(step)
        }
        return doc
    }
}
