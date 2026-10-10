import AppKit

/// What happens to marks that reach past the edge of the captured image.
enum OutsideMode: String, CaseIterable, Identifiable {
    case expandWhite, expandClear, clip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expandWhite: return "Add white space"
        case .expandClear: return "Add transparent space"
        case .clip: return "Cut off at the image edge"
        }
    }
}

/// A capture plus its editable annotations and undo history.
final class CaptureDocument {
    private(set) var base: CGImage
    let scale: CGFloat
    let url: URL
    var annotations: [Annotation] = []
    var dirty = false
    /// The image last written to the edit store, so it is only rewritten when it changes.
    var savedBase: CGImage?

    private var undoStack: [(CGImage, [Annotation])] = []
    private var redoStack: [(CGImage, [Annotation])] = []

    init(base: CGImage, scale: CGFloat, url: URL) {
        self.base = base
        self.scale = scale
        self.url = url
    }

    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }
    var imageRect: CGRect { CGRect(origin: .zero, size: pixelSize) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call before any mutation so it can be undone.
    func checkpoint() {
        undoStack.append((base, annotations))
        redoStack.removeAll()
        dirty = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append((base, annotations))
        (base, annotations) = previous
        dirty = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((base, annotations))
        (base, annotations) = next
        dirty = true
    }

    // MARK: Snapped marks

    /// `id` and every mark snapped to it, directly or through others: they move as one.
    /// `ignoringOwnLinks` leaves out whatever the mark's own ends are snapped to.
    func group(of id: UUID, ignoringOwnLinks: Bool = false) -> Set<UUID> {
        let present = Set(annotations.map(\.id))
        var group: Set<UUID> = [id]
        var grew = true
        while grew {
            grew = false
            for annotation in annotations {
                let targets = ignoringOwnLinks && annotation.id == id ? []
                    : [annotation.startLink, annotation.endLink].compactMap { $0?.target }.filter(present.contains)
                if group.contains(annotation.id) {
                    for target in targets where group.insert(target).inserted { grew = true }
                } else if targets.contains(where: group.contains) {
                    group.insert(annotation.id)
                    grew = true
                }
            }
        }
        return group
    }

    func isSnapped(_ id: UUID) -> Bool { group(of: id).count > 1 }

    /// Puts every snapped line end back on the mark it is snapped to, wherever that mark now is.
    func resolveLinks() {
        guard annotations.contains(where: { $0.startLink != nil || $0.endLink != nil }) else { return }
        for _ in 0..<2 { // twice, so a line snapped to another snapped line settles
            let marks = Dictionary(annotations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for i in annotations.indices {
                if let link = annotations[i].startLink, let p = marks[link.target]?.point(at: link.anchor) {
                    annotations[i].start = p
                }
                if let link = annotations[i].endLink, let p = marks[link.target]?.point(at: link.anchor) {
                    annotations[i].end = p
                }
            }
        }
    }

    /// Unsnaps everything that was snapped onto mark `id`.
    func removeLinks(to id: UUID) {
        for i in annotations.indices {
            if annotations[i].startLink?.target == id { annotations[i].startLink = nil }
            if annotations[i].endLink?.target == id { annotations[i].endLink = nil }
        }
    }

    /// Unsnaps mark `id` from everything: what it is snapped to and what is snapped to it.
    func unsnap(_ id: UUID) {
        removeLinks(to: id)
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].startLink = nil
        annotations[i].endLink = nil
    }

    /// The area the finished picture covers, in image pixels: the image itself, grown on any
    /// side where a mark reaches past it. A stroke merely straddling the edge doesn't count.
    func contentRect(_ mode: OutsideMode, including extra: [Annotation] = []) -> CGRect {
        guard mode != .clip else { return imageRect }
        let slack = 4 * scale
        var minX: CGFloat = 0, minY: CGFloat = 0, maxX = pixelSize.width, maxY = pixelSize.height
        for annotation in annotations + extra {
            let b = annotation.visualBounds
            guard !b.isNull, !b.isEmpty else { continue }
            if b.minX < -slack { minX = min(minX, b.minX) }
            if b.minY < -slack { minY = min(minY, b.minY) }
            if b.maxX > pixelSize.width + slack { maxX = max(maxX, b.maxX) }
            if b.maxY > pixelSize.height + slack { maxY = max(maxY, b.maxY) }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    /// Draws into a flipped context in image-pixel coordinates.
    func draw(in ctx: CGContext, draft: Annotation? = nil, clipToImage: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.drawFlipped(base, in: imageRect)
        ctx.saveGState()
        if clipToImage { ctx.clip(to: imageRect) }
        for annotation in annotations { annotation.draw(in: ctx, base: base) }
        draft?.draw(in: ctx, base: base)
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The finished picture. `opaque` swaps a transparent surround for white (for formats without alpha).
    func render(outside mode: OutsideMode, opaque: Bool = false) -> CGImage {
        let rect = contentRect(mode)
        guard let ctx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        if mode == .expandWhite || opaque {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
        }
        draw(in: ctx)
        return ctx.makeImage() ?? base
    }

    /// Flattens annotations and crops to `rect` (image pixels).
    func crop(to rect: CGRect, outside mode: OutsideMode) {
        let content = contentRect(mode)
        let r = rect.integral.intersection(content)
        guard r.width >= 4, r.height >= 4,
              let cropped = render(outside: mode).cropping(to: r.offsetBy(dx: -content.minX, dy: -content.minY))
        else { return }
        checkpoint()
        base = cropped
        annotations = []
    }
}
