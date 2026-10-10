import AppKit

/// The editing surface. Drawing and annotation geometry are in image pixels; the view itself
/// covers `workspace`, which is the picture plus a margin marks can be dragged out into.
final class CanvasView: NSView, NSTextFieldDelegate {
    weak var controller: EditorController?

    var doc: CaptureDocument? {
        didSet {
            cancelTextEditing()
            selected = nil
            draft = nil
            syncSize()
        }
    }

    private(set) var selected: Int? {
        didSet {
            needsDisplay = true
            if selected != oldValue { controller?.selectionChanged(selectedAnnotation) }
        }
    }
    private var draft: Annotation? { didSet { needsDisplay = true } }
    /// Mark under the cursor that a click would grab; drawn with a glow.
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private enum Drag: Equatable { case none, move, moveStart, resizeStart, resizeEnd, scaleText, boxEdge(Int) }
    private var drag: Drag = .none
    /// The mark as it was when the drag began, and where the drag began.
    private var dragOriginal: Annotation?
    private var dragOrigin: CGPoint = .zero
    /// The marks snapped to the one being moved, which travel with it, as they were when the drag began.
    private var dragGroup: [(index: Int, original: Annotation)] = []
    /// Where a line end is currently snapping, shown as a ring.
    private var snapMarker: CGPoint? { didSet { if snapMarker != oldValue { needsDisplay = true } } }
    /// How many times the current clipboard has been pasted, to stagger the copies.
    private var pasteCount = 0
    private var menuPoint: CGPoint?
    /// The part of image-pixel space this view shows.
    private var workspace: CGRect = .zero
    private var outsideMode: OutsideMode { controller?.outsideMode ?? .expandWhite }
    private var lastDrag: CGPoint = .zero
    private var dragCheckpointed = false

    /// The text box or callout currently being typed into `field`.
    private var editing: Annotation? { didSet { needsDisplay = true } }
    private var field: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var selectedAnnotation: Annotation? {
        guard let doc, let i = selected, i < doc.annotations.count else { return nil }
        return doc.annotations[i]
    }

    /// Image pixels per on-screen point, so grab areas and handles stay the same size at any zoom.
    private var unit: CGFloat {
        (doc?.scale ?? 1) / max(enclosingScrollView?.magnification ?? 1, 0.05)
    }

    /// Refits the view around the picture. Returns true if its size changed.
    @discardableResult
    func syncSize() -> Bool {
        needsDisplay = true
        guard let doc else {
            workspace = .zero
            setFrameSize(.zero)
            return false
        }
        // Always leave room to drag a mark further out than the picture currently reaches.
        let margin = 80 * doc.scale
        let next = doc.contentRect(outsideMode == .clip ? .expandWhite : outsideMode, including: editing.map { [$0] } ?? [])
            .insetBy(dx: -margin, dy: -margin)
        guard next != workspace else { return false }
        let resized = next.size != workspace.size
        workspace = next
        setFrameSize(NSSize(width: next.width / doc.scale, height: next.height / doc.scale))
        layoutField()
        return resized
    }

    /// Where an image-pixel position sits in this view.
    func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        let scale = doc?.scale ?? 1
        return CGPoint(x: (imagePoint.x - workspace.minX) / scale, y: (imagePoint.y - workspace.minY) / scale)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        guard let doc else { return .zero }
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x * doc.scale + workspace.minX, workspace.minX), workspace.maxX),
                       y: min(max(p.y * doc.scale + workspace.minY, workspace.minY), workspace.maxY))
    }

    private func makeAnnotation(_ tool: Tool, at p: CGPoint) -> Annotation {
        Annotation(tool: tool, at: p, style: controller?.style(for: tool) ?? .standard(for: tool),
                   scale: doc?.scale ?? 1)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    /// Topmost mark a press at `p` would grab. Every tool grabs marks by their visible parts.
    /// The empty inside of an unfilled box or oval also grabs when that mark is selected,
    /// when the Select tool is active, or when ⌘ is held (`anywhere`) — otherwise a press there
    /// draws, so you can still put marks inside a box.
    private func hitIndex(_ p: CGPoint, anywhere: Bool = false) -> Int? {
        guard let doc, let tool = controller?.tool, tool != .crop else { return nil }
        if tool == .pen && !anywhere { return nil } // freehand must be able to scribble over marks
        return doc.annotations.indices.reversed().first {
            doc.annotations[$0].hitTest(p, tolerance: 8 * unit,
                                        interior: anywhere || tool == .select || $0 == selected)
        }
    }

    private func selectedHandle(at p: CGPoint) -> Annotation.HandleKind? {
        guard let annotation = selectedAnnotation, controller?.tool != .crop else { return nil }
        return annotation.handles.first { hypot($0.point.x - p.x, $0.point.y - p.y) <= 11 * unit }?.kind
    }

    override func mouseMoved(with event: NSEvent) {
        guard doc != nil, let controller, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            hovered = nil
            return
        }
        let p = imagePoint(event)
        if let handle = selectedHandle(at: p) {
            hovered = nil
            switch handle {
            case .edge(let side): (side % 2 == 0 ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            default: NSCursor.crosshair.set()
            }
        } else if let i = hitIndex(p, anywhere: event.modifierFlags.contains(.command)) {
            hovered = i
            NSCursor.openHand.set()
        } else {
            hovered = nil
            (controller.tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    // MARK: Snapping

    /// `p` pulled onto a nearby mark if snapping is on, with the link that keeps it there.
    /// ⌘ switches snapping off for one drag.
    private func snap(_ p: CGPoint, excluding: Set<UUID>, event: NSEvent) -> (point: CGPoint, link: Annotation.Link?) {
        guard let doc, controller?.snapEnabled == true, !event.modifierFlags.contains(.command) else {
            snapMarker = nil
            return (p, nil)
        }
        var best: (point: CGPoint, link: Annotation.Link?, distance: CGFloat)?
        for mark in doc.annotations where !excluding.contains(mark.id) {
            guard let q = mark.snapPoint(near: p, tolerance: 10 * unit) else { continue }
            let distance = hypot(q.x - p.x, q.y - p.y)
            if distance < best?.distance ?? .infinity { best = (q, mark.link(at: q), distance) }
        }
        snapMarker = best?.point
        return (best?.point ?? p, best?.link)
    }

    /// Marks an end of `annotation` must not snap onto: itself, and anything already snapped to it.
    private func snapExclusions(for annotation: Annotation) -> Set<UUID> {
        var ids: Set<UUID> = [annotation.id]
        for other in doc?.annotations ?? []
        where other.startLink?.target == annotation.id || other.endLink?.target == annotation.id {
            ids.insert(other.id)
        }
        return ids
    }

    /// Loose line ends that rest on another mark's outline and would be fastened by Snap:
    /// the selected mark's own ends, and other lines' ends resting on the selected mark.
    private var snapCandidates: [(index: Int, isStart: Bool, link: Annotation.Link)] {
        guard let doc, let i = selected, i < doc.annotations.count else { return [] }
        let chosen = doc.annotations[i]
        var result: [(index: Int, isStart: Bool, link: Annotation.Link)] = []
        func check(_ j: Int, isStart: Bool, against targets: [Annotation]) {
            let mark = doc.annotations[j]
            guard isStart ? mark.linksStart && mark.startLink == nil : mark.linksEnd && mark.endLink == nil else { return }
            let p = isStart ? mark.start : mark.end
            let barred = snapExclusions(for: mark)
            for target in targets.reversed() where !barred.contains(target.id) {
                guard let q = target.snapPoint(near: p, tolerance: 4 * unit), let link = target.link(at: q) else { continue }
                result.append((j, isStart, link))
                return
            }
        }
        for isStart in [true, false] { check(i, isStart: isStart, against: doc.annotations) }
        for j in doc.annotations.indices where j != i {
            for isStart in [true, false] { check(j, isStart: isStart, against: [chosen]) }
        }
        return result
    }

    var canSnapSelection: Bool { !snapCandidates.isEmpty }

    var selectionIsSnapped: Bool {
        guard let doc, let annotation = selectedAnnotation else { return false }
        return doc.isSnapped(annotation.id)
    }

    /// Fastens the selected mark to the marks it touches, so they move as one.
    @objc func snapSelected() {
        let candidates = snapCandidates
        guard let doc, !candidates.isEmpty else { return }
        doc.checkpoint()
        for candidate in candidates {
            if candidate.isStart {
                doc.annotations[candidate.index].startLink = candidate.link
            } else {
                doc.annotations[candidate.index].endLink = candidate.link
            }
        }
        needsDisplay = true
        controller?.documentChanged()
        Toast.show("Snapped together")
    }

    /// Unfastens the selected mark from what it is snapped to and from what is snapped to it.
    @objc func unsnapSelected() {
        guard let doc, let annotation = selectedAnnotation, doc.isSnapped(annotation.id) else { return }
        doc.checkpoint()
        doc.unsnap(annotation.id)
        needsDisplay = true
        controller?.documentChanged()
        Toast.show("Unsnapped")
    }

    // MARK: Context menu, copy and paste

    /// Right-click a mark to copy, layer, duplicate or delete it; right-click elsewhere to paste.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard doc != nil else { return nil }
        commitText()
        let p = imagePoint(event)
        menuPoint = p
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if let i = hitIndex(p, anywhere: true) {
            selected = i
            add("Copy", #selector(copy(_:)))
            add("Cut", #selector(cut(_:)))
            add("Duplicate", #selector(duplicateSelected))
            menu.addItem(.separator())
            add("Snap Together", #selector(snapSelected), enabled: canSnapSelection)
            add("Unsnap", #selector(unsnapSelected), enabled: selectionIsSnapped)
            menu.addItem(.separator())
            add("Bring to Front", #selector(bringToFront))
            add("Send to Back", #selector(sendToBack))
            menu.addItem(.separator())
            add("Delete", #selector(delete(_:)))
        } else {
            selected = nil
            add("Paste Here", #selector(pasteAtMenuPoint), enabled: Clipboard.hasMarks)
            menu.addItem(.separator())
            add("Copy Whole Image", #selector(copyWholeImage))
        }
        return menu
    }

    /// The selected mark together with everything snapped to it.
    private var selectedGroup: [Annotation] {
        guard let doc, let annotation = selectedAnnotation else { return [] }
        let group = doc.group(of: annotation.id)
        return doc.annotations.filter { group.contains($0.id) }
    }

    /// ⌘C copies the selected mark and whatever is snapped to it, or the whole annotated image
    /// when nothing is selected.
    @objc func copy(_ sender: Any?) {
        guard let doc, let annotation = selectedAnnotation else {
            controller?.copyImage()
            return
        }
        let marks = selectedGroup
        Clipboard.copy(marks: marks, scale: doc.scale)
        pasteCount = 0
        Toast.show(marks.count > 1 ? "\(marks.count) snapped marks copied" : "\(annotation.tool.title) copied")
    }

    @objc func cut(_ sender: Any?) {
        guard let doc, let annotation = selectedAnnotation else { return }
        copy(sender)
        let group = doc.group(of: annotation.id)
        doc.checkpoint()
        doc.annotations.removeAll { group.contains($0.id) }
        selected = nil
        controller?.documentChanged()
    }

    @objc func paste(_ sender: Any?) { controller?.paste() }
    @objc private func pasteAtMenuPoint() { controller?.paste(at: menuPoint) }
    @objc private func copyWholeImage() { controller?.copyImage() }

    /// Adds copied marks: centred on `point`, or staggered from where they were copied.
    func paste(marks: [Annotation], sourceScale: CGFloat, at point: CGPoint?) {
        guard let doc, !marks.isEmpty else { return }
        commitText()
        pasteCount += 1
        let copies = marks.map { $0.scaled(by: doc.scale / sourceScale) }
        let frame = copies.reduce(CGRect.null) { $0.union($1.bounds) }
        let shift = 16 * doc.scale * CGFloat(pasteCount)
        insert(copies, offset: point.map { CGPoint(x: $0.x - frame.midX, y: $0.y - frame.midY) }
            ?? CGPoint(x: shift, y: shift))
    }

    /// Adds `marks` as new marks moved by `offset`, keeping the snaps between them. Selects the
    /// copy of `selecting`, or the topmost new mark.
    private func insert(_ marks: [Annotation], offset: CGPoint, selecting: UUID? = nil) {
        guard let doc, !marks.isEmpty else { return }
        let ids = Dictionary(marks.map { ($0.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        func remap(_ link: Annotation.Link?) -> Annotation.Link? {
            guard let link, let target = ids[link.target] else { return nil }
            return Annotation.Link(target: target, anchor: link.anchor)
        }
        doc.checkpoint()
        for mark in marks {
            var copy = mark
            copy.id = ids[mark.id] ?? UUID()
            copy.startLink = remap(mark.startLink)
            copy.endLink = remap(mark.endLink)
            copy.translate(dx: offset.x, dy: offset.y)
            if copy.tool == .step { copy.number = doc.annotations.filter { $0.tool == .step }.count + 1 }
            doc.annotations.append(copy)
        }
        let chosen = selecting.flatMap { ids[$0] }
        selected = doc.annotations.firstIndex { $0.id == chosen } ?? doc.annotations.count - 1
        needsDisplay = true
        controller?.documentChanged()
    }

    private func reorderSelected(toFront: Bool) {
        guard let doc, let i = selected, i < doc.annotations.count else { return }
        doc.checkpoint()
        let annotation = doc.annotations.remove(at: i)
        doc.annotations.insert(annotation, at: toFront ? doc.annotations.count : 0)
        selected = toFront ? doc.annotations.count - 1 : 0
        needsDisplay = true
        controller?.documentChanged()
    }

    @objc private func bringToFront() { reorderSelected(toFront: true) }
    @objc private func sendToBack() { reorderSelected(toFront: false) }

    @objc private func duplicateSelected() {
        guard let doc, let annotation = selectedAnnotation else { return }
        insert(selectedGroup, offset: CGPoint(x: 16 * doc.scale, y: 16 * doc.scale), selecting: annotation.id)
    }

    override func mouseDown(with event: NSEvent) {
        guard let doc, let controller else { return }
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        drag = .none
        dragCheckpointed = false
        lastDrag = p
        hovered = nil

        // Reshape the selected mark by one of its handles.
        if let i = selected, let handle = selectedHandle(at: p) {
            switch handle {
            case .start:
                drag = .resizeStart
            case .end:
                drag = .resizeEnd
            case .scale:
                drag = .scaleText
                dragOriginal = doc.annotations[i]
            case .edge(let side):
                drag = .boxEdge(side)
                dragOriginal = doc.annotations[i]
            case .corner(let index):
                // Anchor the opposite corner and drag this one.
                let corners = doc.annotations[i].handles.map(\.point)
                doc.annotations[i].start = corners[(index + 2) % 4]
                doc.annotations[i].end = corners[index]
                drag = .resizeEnd
            }
            return
        }

        // Clicking an existing mark selects it, whichever tool is active.
        if let i = hitIndex(p, anywhere: event.modifierFlags.contains(.command)) {
            let hit = doc.annotations[i]
            if event.clickCount == 2, hit.tool == .text || hit.tool == .callout {
                doc.checkpoint()
                doc.annotations.remove(at: i)
                selected = nil
                beginTextEditing(hit)
                return
            }
            selected = i
            // Dragging a callout by its box leaves the arrow tip where it points.
            drag = hit.tool == .callout && hit.boxRect.contains(p) ? .moveStart : .move
            dragOriginal = hit
            dragOrigin = p
            // Marks snapped to this one travel with it. ⌥ moves it on its own, and snapped
            // line ends stretch to stay on it.
            let group = event.modifierFlags.contains(.option) ? []
                : doc.group(of: hit.id, ignoringOwnLinks: drag == .moveStart).subtracting([hit.id])
            dragGroup = doc.annotations.indices.filter { group.contains(doc.annotations[$0].id) }
                .map { ($0, doc.annotations[$0]) }
            NSCursor.closedHand.set()
            return
        }

        selected = nil
        switch controller.tool {
        case .select:
            break
        case .text:
            beginTextEditing(makeAnnotation(.text, at: p))
        case .step:
            var step = makeAnnotation(.step, at: p)
            step.number = doc.annotations.filter { $0.tool == .step }.count + 1
            doc.checkpoint()
            doc.annotations.append(step)
            selected = doc.annotations.count - 1
            controller.documentChanged()
        case .arrow, .line, .callout:
            // A callout is drawn from its tip, a line from its start.
            let (point, link) = snap(p, excluding: [], event: event)
            var mark = makeAnnotation(controller.tool, at: point)
            if mark.tool == .callout { mark.endLink = link } else { mark.startLink = link }
            draft = mark
        default:
            draft = makeAnnotation(controller.tool, at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let doc else { return }
        var p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)

        if var d = draft {
            if d.tool == .callout {
                d.start = p // the box follows the cursor; the tip stays where the drag began
            } else {
                if shift {
                    p = constrain(p, from: d.start, tool: d.tool)
                    d.endLink = nil
                } else if d.tool == .arrow || d.tool == .line {
                    (p, d.endLink) = snap(p, excluding: [], event: event)
                }
                d.end = p
                if d.tool == .pen { d.points.append(p) }
            }
            draft = d
        } else if drag != .none, let i = selected, i < doc.annotations.count {
            if !dragCheckpointed {
                doc.checkpoint()
                dragCheckpointed = true
            }
            var annotation = doc.annotations[i]
            switch drag {
            case .move, .moveStart:
                guard let original = dragOriginal else { break }
                var dx = p.x - dragOrigin.x, dy = p.y - dragOrigin.y
                annotation = original
                if drag == .moveStart {
                    annotation.start = CGPoint(x: original.start.x + dx, y: original.start.y + dy)
                } else {
                    if original.linksStart {
                        // A line being moved snaps on when one of its loose ends comes near another mark.
                        let moving = snapExclusions(for: original).union(dragGroup.map(\.original.id))
                        for isStart in [false, true] where (isStart ? original.startLink : original.endLink) == nil {
                            let end = isStart ? original.start : original.end
                            let moved = CGPoint(x: end.x + dx, y: end.y + dy)
                            let (target, link) = snap(moved, excluding: moving, event: event)
                            guard let link else { continue }
                            dx += target.x - moved.x
                            dy += target.y - moved.y
                            if isStart { annotation.startLink = link } else { annotation.endLink = link }
                            break
                        }
                    }
                    annotation.translate(dx: dx, dy: dy)
                }
                for member in dragGroup where member.index < doc.annotations.count {
                    var moved = member.original
                    moved.translate(dx: dx, dy: dy)
                    doc.annotations[member.index] = moved
                }
            case .resizeStart:
                // Dropping a line end on a mark snaps it there; dragging it off unsnaps it.
                if shift {
                    annotation.start = constrain(p, from: annotation.end, tool: annotation.tool)
                    annotation.startLink = nil
                } else if annotation.linksStart {
                    (annotation.start, annotation.startLink) = snap(p, excluding: snapExclusions(for: annotation), event: event)
                } else {
                    annotation.start = p
                }
            case .resizeEnd:
                if shift {
                    annotation.end = constrain(p, from: annotation.start, tool: annotation.tool)
                    annotation.endLink = nil
                } else if annotation.linksEnd {
                    (annotation.end, annotation.endLink) = snap(p, excluding: snapExclusions(for: annotation), event: event)
                } else {
                    annotation.end = p
                }
            case .scaleText:
                // Grow or shrink the type so the box's corner follows the cursor.
                if let original = dragOriginal {
                    let box = original.boxRect
                    let factor = max((p.x - box.minX) / box.width, (p.y - box.minY) / box.height)
                    annotation.fontSize = min(max(original.fontSize * factor, Style.minFontSize * doc.scale),
                                              Style.maxFontSize * doc.scale)
                    // A box with a set width or height scales with its type.
                    let applied = annotation.fontSize / original.fontSize
                    annotation.boxWidth = original.boxWidth.map { $0 * applied }
                    annotation.boxHeight = original.boxHeight.map { $0 * applied }
                }
            case .boxEdge(let side):
                // Drag one side of a text box: left/right set the width text wraps to,
                // top/bottom set the height. The opposite side stays put.
                if let original = dragOriginal {
                    let content = original.contentRect, pad = original.boxPadding
                    let minWidth = original.fontSize, minHeight = original.textSize.height
                    switch side {
                    case 0:
                        let left = min(p.x + pad.width, content.maxX - minWidth)
                        annotation.start.x = left
                        annotation.boxWidth = content.maxX - left
                    case 2:
                        annotation.boxWidth = max(p.x - pad.width - content.minX, minWidth)
                    case 1:
                        let top = min(p.y + pad.height, content.maxY - minHeight)
                        annotation.start.y = top
                        annotation.boxHeight = content.maxY - top
                    default:
                        annotation.boxHeight = max(p.y - pad.height - content.minY, minHeight)
                    }
                }
            case .none:
                break
            }
            doc.annotations[i] = annotation
            doc.resolveLinks() // snapped line ends stay on the marks they are snapped to
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if drag == .scaleText { controller?.selectionChanged(selectedAnnotation) } // show the new size
        drag = .none
        dragOriginal = nil
        dragGroup = []
        snapMarker = nil
        if dragCheckpointed { controller?.documentChanged() }
        dragCheckpointed = false
        guard let doc, let d = draft else { return }
        draft = nil
        if d.tool == .crop {
            doc.crop(to: d.rect, outside: outsideMode)
            syncSize()
            controller?.documentChanged(resized: true)
        } else if d.tool == .callout {
            beginTextEditing(d)
        } else if !d.isDegenerate {
            doc.checkpoint()
            doc.annotations.append(d)
            // Leave the new mark selected so it can be nudged or reshaped straight away.
            // Freehand strokes are the exception: a box around each one gets in the way.
            if d.tool != .pen { selected = doc.annotations.count - 1 }
            controller?.documentChanged()
        }
    }

    /// Shift: squares for box tools, 45° steps for lines.
    private func constrain(_ p: CGPoint, from start: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        switch tool {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .pen, .callout:
            return p
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
    }

    // MARK: Keyboard & menu actions

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete, forward delete
            deleteSelected()
        } else if event.keyCode == 53 { // esc
            draft = nil
            selected = nil
        } else if let step = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0),
                              125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)][event.keyCode],
                  let doc, let i = selected, i < doc.annotations.count {
            // Arrow keys nudge the selected mark and whatever is snapped to it; Shift moves it further.
            let distance = (event.modifierFlags.contains(.shift) ? 10 : 1) * doc.scale
            let group = doc.group(of: doc.annotations[i].id)
            doc.checkpoint()
            for j in doc.annotations.indices where group.contains(doc.annotations[j].id) {
                doc.annotations[j].translate(dx: step.x * distance, dy: step.y * distance)
            }
            needsDisplay = true
            controller?.documentChanged()
        } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let ch = event.charactersIgnoringModifiers?.lowercased().first,
                  let tool = Tool.allCases.first(where: { $0.key == ch }) {
            controller?.tool = tool
        } else {
            super.keyDown(with: event)
        }
    }

    private func deleteSelected() {
        guard let doc, let i = selected, i < doc.annotations.count else { return }
        doc.checkpoint()
        doc.removeLinks(to: doc.annotations.remove(at: i).id)
        selected = nil
        controller?.documentChanged()
    }

    @objc func delete(_ sender: Any?) { deleteSelected() }

    @objc func undo(_ sender: Any?) {
        commitText()
        selected = nil
        doc?.undo()
        syncSize()
        controller?.documentChanged(resized: true)
    }

    @objc func redo(_ sender: Any?) {
        commitText()
        selected = nil
        doc?.redo()
        syncSize()
        controller?.documentChanged(resized: true)
    }

    func fitSelectedBox() {
        guard let doc, let i = selected, i < doc.annotations.count, doc.annotations[i].tool.usesFont,
              doc.annotations[i].boxWidth != nil || doc.annotations[i].boxHeight != nil else { return }
        doc.checkpoint()
        doc.annotations[i].boxWidth = nil
        doc.annotations[i].boxHeight = nil
        needsDisplay = true
        controller?.documentChanged()
    }

    func toolChanged() {
        commitText()
        draft = nil
        if controller?.tool != .select { selected = nil }
    }

    /// Applies the style panel to whatever is being typed or is selected.
    func styleChanged() {
        guard let doc, let style = controller?.style else { return }
        if var annotation = editing, let field {
            annotation.apply(style, scale: doc.scale)
            editing = annotation
            field.textColor = annotation.textColor
            field.font = annotation.font(size: annotation.fontSize / doc.scale)
            layoutField()
        } else if let i = selected, i < doc.annotations.count {
            doc.checkpoint()
            doc.annotations[i].apply(style, scale: doc.scale)
            needsDisplay = true
            controller?.documentChanged()
        }
    }

    // MARK: Text editing

    private func beginTextEditing(_ annotation: Annotation) {
        guard let doc else { return }
        editing = annotation
        controller?.selectionChanged(annotation)
        let field = NSTextField(string: annotation.text)
        field.font = annotation.font(size: annotation.fontSize / doc.scale)
        field.textColor = annotation.textColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        addSubview(field)
        self.field = field
        layoutField()
        window?.makeFirstResponder(field)
    }

    private func layoutField() {
        guard let doc, let field, let annotation = editing else { return }
        // Placed over where the words will be drawn. NSTextField insets its text by 2pt each side.
        // A box that hugs its text gets slack so typing never wraps; a set width wraps as drawn.
        let text = annotation.textRect
        let origin = viewPoint(text.origin)
        let fixedWidth = annotation.boxWidth != nil
        field.alignment = fixedWidth ? annotation.hAlign.textAlignment : .left
        field.frame = NSRect(x: origin.x - 2, y: origin.y,
                             width: text.width / doc.scale + (fixedWidth ? 4 : 40),
                             height: text.height / doc.scale + 4)
    }

    func controlTextDidChange(_ obj: Notification) {
        editing?.text = field?.stringValue ?? ""
        layoutField()
    }

    /// ⇧Return adds a line; plain Return finishes. (⌥Return already adds a line.)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              NSApp.currentEvent?.modifierFlags.contains(.shift) == true else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.field == nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    func commitText() {
        guard let field, var annotation = editing, let doc else { return }
        self.field = nil
        editing = nil
        annotation.text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        // An empty callout or box stays put, ready to be typed in later (double-click it).
        // Only a mark with nothing at all to show is dropped.
        let hasWords = !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasWords || annotation.tool == .callout || annotation.fill != nil || annotation.stroke != nil {
            doc.checkpoint()
            doc.annotations.append(annotation)
            selected = doc.annotations.count - 1
            controller?.documentChanged()
        } else {
            doc.removeLinks(to: annotation.id)
        }
        controller?.selectionChanged(selectedAnnotation)
        needsDisplay = true
    }

    private func cancelTextEditing() {
        field?.delegate = nil
        field?.removeFromSuperview()
        field = nil
        editing = nil
    }

    // MARK: Drawing

    private func drawCheckerboard(_ ctx: CGContext, in rect: CGRect, cell: CGFloat) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : cell)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell * 2
            }
            y += cell
            row += 1
        }
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let doc, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / doc.scale, y: 1 / doc.scale)
        ctx.translateBy(x: -workspace.minX, y: -workspace.minY)

        let isCropping = draft?.tool == .crop
        let pending = [isCropping ? nil : draft, editing].compactMap { $0 }
        let content = doc.contentRect(outsideMode, including: pending).intersection(workspace)
        if content != doc.imageRect {
            // The space the finished picture gains to fit marks that reach past the image.
            if outsideMode == .expandWhite {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(content)
            } else {
                drawCheckerboard(ctx, in: content, cell: 8 * doc.scale)
            }
        }
        doc.draw(in: ctx, draft: isCropping ? nil : draft, clipToImage: outsideMode == .clip)
        ctx.saveGState()
        if outsideMode == .clip { ctx.clip(to: doc.imageRect) }
        editing?.draw(in: ctx, base: doc.base, showsText: false)
        ctx.restoreGState()

        if isCropping, let crop = draft?.rect {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addRect(content)
            ctx.addRect(crop)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(doc.scale)
            ctx.stroke(crop)
        }

        let unit = self.unit
        // Glow under the cursor: this mark will be grabbed. Marks snapped to it, or to the
        // selected mark, glow more faintly: they come along.
        var glow: [UUID: CGFloat] = [:]
        if let chosen = selectedAnnotation {
            for id in doc.group(of: chosen.id) { glow[id] = 0.3 }
        }
        if let i = hovered, i != selected, i < doc.annotations.count {
            let under = doc.annotations[i].id
            for id in doc.group(of: under) { glow[id] = id == under ? 0.55 : max(glow[id] ?? 0, 0.3) }
        }
        glow[selectedAnnotation?.id ?? UUID()] = nil
        for annotation in doc.annotations {
            guard let alpha = glow[annotation.id] else { continue }
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor)
            ctx.setLineCap(.round)
            switch annotation.tool {
            case .line, .arrow:
                ctx.setLineWidth(annotation.lineWidth + 8 * unit)
                ctx.strokeLineSegments(between: [annotation.start, annotation.end])
            case .ellipse:
                ctx.setLineWidth(3 * unit)
                ctx.strokeEllipse(in: annotation.bounds.insetBy(dx: -2 * unit, dy: -2 * unit))
            default:
                let outline = annotation.tool == .callout ? annotation.boxRect : annotation.bounds
                ctx.setLineWidth(3 * unit)
                ctx.stroke(outline.insetBy(dx: -3 * unit, dy: -3 * unit))
            }
            // A pin where each of its ends is snapped on.
            let pins = [annotation.startLink == nil ? nil : annotation.start, annotation.endLink == nil ? nil : annotation.end]
            for pin in pins.compactMap({ $0 }) {
                let dot = CGRect(x: pin.x - 4.5 * unit, y: pin.y - 4.5 * unit, width: 9 * unit, height: 9 * unit)
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5 * unit)
                ctx.fillEllipse(in: dot)
                ctx.strokeEllipse(in: dot)
            }
        }

        if let snap = snapMarker {
            // Where the line end being dragged will stick.
            let ring = CGRect(x: snap.x - 7 * unit, y: snap.y - 7 * unit, width: 14 * unit, height: 14 * unit)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(2 * unit)
            ctx.fillEllipse(in: ring)
            ctx.strokeEllipse(in: ring)
        }

        if let annotation = selectedAnnotation {
            let pad = 4 * unit
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(unit)
            switch annotation.tool {
            case .line, .arrow:
                break
            case .rect, .ellipse, .highlight, .blur:
                ctx.stroke(annotation.rect)
            default:
                let outline = annotation.tool == .callout ? annotation.boxRect : annotation.bounds
                ctx.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
                ctx.stroke(outline.insetBy(dx: -pad, dy: -pad))
                ctx.setLineDash(phase: 0, lengths: [])
            }
            let radius = 6 * unit
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setLineWidth(2 * unit)
            for handle in annotation.handles {
                if case .edge = handle.kind {
                    // Side grips are square, to tell them from the round reshape and resize grips.
                    let side = 4.5 * unit
                    let square = CGRect(x: handle.point.x - side, y: handle.point.y - side, width: side * 2, height: side * 2)
                    ctx.fill(square)
                    ctx.stroke(square)
                } else {
                    // A snapped end's grip is filled in.
                    var isSnapped = false
                    if case .start = handle.kind { isSnapped = annotation.startLink != nil }
                    if case .end = handle.kind { isSnapped = annotation.endLink != nil }
                    let dot = CGRect(x: handle.point.x - radius, y: handle.point.y - radius,
                                     width: radius * 2, height: radius * 2)
                    ctx.setFillColor((isSnapped ? NSColor.controlAccentColor : .white).cgColor)
                    ctx.setStrokeColor((isSnapped ? NSColor.white : .controlAccentColor).cgColor)
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                }
            }
        }
        ctx.restoreGState()
    }
}
