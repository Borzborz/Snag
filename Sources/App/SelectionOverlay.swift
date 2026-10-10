import AppKit

/// Full-screen picker shown over a frozen frame of every display.
/// Drag to select a region, click to take the window under the cursor, Esc to cancel.
final class SelectionSession {
    struct Result {
        let image: CGImage
        let scale: CGFloat
    }

    private let shots: [Shot]
    private let completion: (Result?) -> Void
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?

    init(shots: [Shot], completion: @escaping (Result?) -> Void) {
        self.shots = shots
        self.completion = completion
    }

    func begin() {
        let windowRects = Self.onScreenWindowRects()
        for shot in shots {
            let frame = shot.screen.frame
            let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            container.wantsLayer = true
            container.layer?.contents = shot.image
            let view = SelectionView(frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            view.shot = shot
            view.windowRects = windowRects.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
            view.onFinish = { [weak self] in self?.finish($0) }
            container.addSubview(view)
            window.contentView = container
            windows.append(window)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: // Esc
                self?.finish(nil)
            case 3, 36, 76, 49: // F, Return, Enter, Space: the whole screen under the cursor
                self?.captureFullScreen()
            default:
                return event
            }
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        let underMouse = windows.first { $0.frame.contains(mouse) } ?? windows.first
        underMouse?.makeKeyAndOrderFront(nil)
        if let view = underMouse?.contentView?.subviews.first as? SelectionView {
            underMouse?.makeFirstResponder(view)
            view.mouse = underMouse.map { CGPoint(x: mouse.x - $0.frame.minX, y: mouse.y - $0.frame.minY) }
        }
    }

    private func captureFullScreen() {
        let mouse = NSEvent.mouseLocation
        let window = windows.first { $0.frame.contains(mouse) } ?? windows.first
        (window?.contentView?.subviews.first as? SelectionView)?.captureFullScreen()
    }

    private func finish(_ result: Result?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }

    /// Frames of app windows, front to back, in Cocoa global coordinates. Besides normal windows
    /// this takes the floating ones apps keep above them — plug-in windows, inspectors, palettes,
    /// open menus and popovers — but only from apps with a Dock presence, so the invisible
    /// overlays that background helpers park over the screen are not mistaken for windows.
    private static func onScreenWindowRects() -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        var isRegularApp: [Int: Bool] = [:]
        return info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int, pid != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict),
                  b.width > 40, b.height > 40 else { return nil }
            if layer != 0 {
                guard (layer > 0 && layer < dockLayer) || layer == popUpMenuLayer else { return nil }
                let regular = isRegularApp[pid] ?? (NSRunningApplication(processIdentifier: pid_t(pid))?
                    .activationPolicy == .regular)
                isRegularApp[pid] = regular
                guard regular else { return nil }
            }
            return CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var shot: Shot!
    var windowRects: [CGRect] = []
    var onFinish: ((SelectionSession.Result?) -> Void)?

    var mouse: CGPoint? { didSet { needsDisplay = true } }
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private var dragRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent, hypot(a.x - b.x, a.y - b.y) >= 4 else { return nil }
        return CGRect(p1: a, p2: b)
    }

    /// What a plain click captures: the window under the cursor, or the whole screen when the
    /// cursor is over the menu bar, a screen edge, or bare desktop.
    private var hoverRect: CGRect? {
        guard let mouse else { return nil }
        let menuBar = max(shot.screen.frame.maxY - shot.screen.visibleFrame.maxY, 6)
        let nearEdge = mouse.y >= bounds.height - menuBar || mouse.y <= 4 || mouse.x <= 4 || mouse.x >= bounds.width - 4
        if nearEdge { return bounds }
        return windowRects.first { $0.contains(mouse) }?.intersection(bounds) ?? bounds
    }

    func captureFullScreen() {
        dragStart = nil
        dragCurrent = nil
        onFinish?(crop(bounds))
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = location(event)
    }

    override func mouseExited(with event: NSEvent) {
        if dragStart == nil { mouse = nil }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = location(event)
        dragCurrent = dragStart
        mouse = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = location(event)
        mouse = dragCurrent
    }

    override func mouseUp(with event: NSEvent) {
        let selection = dragRect ?? hoverRect ?? bounds
        dragStart = nil
        dragCurrent = nil
        onFinish?(crop(selection))
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    private func crop(_ selection: CGRect) -> SelectionSession.Result? {
        let s = shot.scale
        let r = CGRect(x: selection.minX * s, y: (bounds.height - selection.maxY) * s,
                       width: selection.width * s, height: selection.height * s).integral
        guard r.width >= 2, r.height >= 2, let image = shot.image.cropping(to: r) else { return nil }
        return .init(image: image, scale: s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let selection = dragRect ?? (dragStart == nil ? hoverRect : nil)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(bounds)
        if let selection { ctx.addRect(selection) }
        ctx.fillPath(using: .evenOdd)

        if let selection {
            let accent = NSColor(srgbRed: 1.0, green: 0.33, blue: 0.10, alpha: 1)
            if dragRect == nil {
                // Hovered window: tint it so it is obvious what a click will take.
                ctx.setFillColor(accent.withAlphaComponent(0.10).cgColor)
                ctx.fill(selection)
            }
            // Border sits just outside the captured area: dark halo, then a bright line.
            // (pulled inside the screen edge when the whole screen is the target).
            let edge = selection.insetBy(dx: -1.5, dy: -1.5).intersection(bounds.insetBy(dx: 2.5, dy: 2.5))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(5)
            ctx.stroke(edge)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(edge)
            // Corner grips
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            for corner in [CGPoint(x: edge.minX, y: edge.minY), CGPoint(x: edge.maxX, y: edge.minY),
                           CGPoint(x: edge.minX, y: edge.maxY), CGPoint(x: edge.maxX, y: edge.maxY)] {
                let grip = CGRect(x: corner.x - 4.5, y: corner.y - 4.5, width: 9, height: 9)
                ctx.fill(grip)
                ctx.stroke(grip)
            }
            drawSizeLabel(for: selection)
        }

        guard let mouse else { return }
        if dragStart == nil {
            let hint = hoverRect == bounds
                ? "Click to capture the full screen  ·  Drag to select an area  ·  Esc to cancel"
                : "Click to capture this window  ·  Drag to select an area  ·  F for full screen  ·  Esc to cancel"
            drawPill(hint, at: CGPoint(x: bounds.midX, y: bounds.height - 70), fontSize: 13, centered: true)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokeLineSegments(between: [CGPoint(x: 0, y: mouse.y), CGPoint(x: bounds.width, y: mouse.y),
                                             CGPoint(x: mouse.x, y: 0), CGPoint(x: mouse.x, y: bounds.height)])
        }
        drawLoupe(ctx, at: mouse)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let s = shot.scale
        let text = "\(Int((selection.width * s).rounded())) × \(Int((selection.height * s).rounded()))"
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + 22 > bounds.height { origin.y = selection.maxY - 28 }
        drawPill(text, at: origin)
    }

    private func drawPill(_ text: String, at origin: CGPoint, fontSize: CGFloat = 11, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: origin.x - (centered ? size.width / 2 + 6 : 0), y: origin.y,
                          width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: attrs)
    }

    private func drawLoupe(_ ctx: CGContext, at mouse: CGPoint) {
        let side: CGFloat = 116
        let samplePoints: CGFloat = 14.5 // points of screen shown inside the loupe
        var origin = CGPoint(x: mouse.x + 22, y: mouse.y - 22 - side)
        if origin.x + side > bounds.width - 8 { origin.x = mouse.x - 22 - side }
        if origin.y < 30 { origin.y = mouse.y + 22 }
        let rect = CGRect(origin: origin, size: CGSize(width: side, height: side))

        let s = shot.scale
        let px = mouse.x * s, py = (bounds.height - mouse.y) * s
        let half = samplePoints * s / 2
        let source = CGRect(x: px - half, y: py - half, width: half * 2, height: half * 2)

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(rect)
        let imageBounds = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        let clipped = source.intersection(imageBounds)
        if !clipped.isEmpty, let piece = shot.image.cropping(to: clipped) {
            let k = side / source.width
            let dest = CGRect(x: rect.minX + (clipped.minX - source.minX) * k,
                              y: rect.minY + (source.maxY - clipped.maxY) * k,
                              width: clipped.width * k, height: clipped.height * k)
            ctx.interpolationQuality = .none
            ctx.draw(piece, in: dest)
        }
        // Centre reticle
        let cell = side / samplePoints
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: rect.midX - cell / 2, y: rect.midY - cell / 2, width: cell, height: cell))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.strokePath()

        drawPill("\(Int(px)), \(Int(py))", at: CGPoint(x: rect.minX, y: rect.minY - 24))
    }
}
