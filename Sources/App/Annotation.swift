import AppKit

enum Tool: String, CaseIterable, Identifiable, Codable {
    // Order is the order shown in the tool palette.
    case select, arrow, line, text, callout, rect, ellipse, pen, highlight, blur, step, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .text: return "character.textbox"
        case .callout: return "text.bubble"
        case .rect: return "rectangle"
        case .ellipse: return "oval"
        case .pen: return "scribble.variable"
        case .highlight: return "highlighter"
        case .blur: return "checkerboard.rectangle"
        case .step: return "1.circle.fill"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .text: return "Text Box"
        case .callout: return "Callout"
        case .rect: return "Box"
        case .ellipse: return "Oval"
        case .pen: return "Draw"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .step: return "Steps"
        case .crop: return "Crop"
        }
    }

    var hint: String {
        switch self {
        case .select: return "Click a mark to move, resize or delete it"
        case .arrow: return "Drag to draw an arrow"
        case .line: return "Drag to draw a straight line"
        case .text: return "Click to type in a text box. ⇧Return starts a new line"
        case .callout: return "Text box with an arrow: drag from what you’re pointing at to where the text goes. ⇧Return starts a new line"
        case .rect: return "Drag to draw a box"
        case .ellipse: return "Drag to draw an oval"
        case .pen: return "Draw freehand"
        case .highlight: return "Drag over an area to highlight it"
        case .blur: return "Drag over an area to hide it"
        case .step: return "Click to drop numbered steps"
        case .crop: return "Drag to crop the image"
        }
    }

    var key: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .text: return "t"
        case .callout: return "k"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlight: return "h"
        case .blur: return "b"
        case .step: return "n"
        case .crop: return "c"
        }
    }

    var hasStyle: Bool { self != .select && self != .crop }
    var usesFill: Bool { hasStyle && self != .blur }
    var usesText: Bool { self == .text || self == .callout || self == .step }
    /// Has its own font, size and bold controls.
    var usesFont: Bool { self == .text || self == .callout }
    /// Has a body thickness separate from its border: lines, a callout's arrow, step size.
    var usesThickness: Bool { [.arrow, .line, .pen, .callout, .step].contains(self) }
    /// Still visible with neither fill nor border.
    var allowsNoColor: Bool { usesText || self == .blur }
}

enum HAlign: String, CaseIterable, Codable {
    case left, center, right

    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    var textAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

enum VAlign: String, CaseIterable, Codable {
    case top, middle, bottom

    var symbol: String {
        switch self {
        case .top: return "arrow.up.to.line"
        case .middle: return "arrow.up.and.line.horizontal.and.arrow.down"
        case .bottom: return "arrow.down.to.line"
        }
    }
}

extension NSColor {
    // sRGB so colours compare equal after a round trip through a saved file.
    static let ink = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let paper = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}

/// What the style panel edits. `nil` means "no colour".
struct Style: Equatable {
    var fill: NSColor?
    var stroke: NSColor?
    var text: NSColor
    /// Points: how thick a line, arrow or pen stroke is. Also sizes step numbers.
    var width: CGFloat
    /// Points: thickness of the border (outline) drawn in the border colour.
    var borderWidth: CGFloat = 2
    /// Text boxes and callouts. An empty family means the system font.
    var fontFamily = ""
    var fontSize: CGFloat = 22
    var bold = true
    /// Where the text sits inside a text box or callout.
    var hAlign = HAlign.left
    var vAlign = VAlign.middle

    static let minBorderWidth: CGFloat = 1
    static let maxBorderWidth: CGFloat = 30
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 200

    static let red = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)
    static let yellow = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)

    static func standard(for tool: Tool) -> Style {
        switch tool {
        case .rect, .ellipse:
            return Style(fill: nil, stroke: red, text: .ink, width: 4, borderWidth: 4)
        case .text, .callout:
            return Style(fill: .paper, stroke: red, text: .ink, width: 4)
        case .highlight:
            return Style(fill: yellow, stroke: nil, text: .ink, width: 4)
        case .blur:
            return Style(fill: nil, stroke: nil, text: .ink, width: 4)
        case .step:
            return Style(fill: red, stroke: nil, text: .paper, width: 4)
        default:
            return Style(fill: red, stroke: nil, text: .ink, width: 4)
        }
    }
}

/// One mark on a capture. All geometry is in image pixels with a top-left origin.
struct Annotation {
    /// `scale` is the corner grip that resizes a text box's type; `edge` (0 left, 1 top, 2 right,
    /// 3 bottom) drags one side of a text box to set its width or height.
    enum HandleKind { case start, end, corner(Int), scale, edge(Int) }

    /// A line end snapped onto another mark. `anchor` says where on that mark, as fractions of
    /// its outline's width and height (on a line: how far along it), so the end keeps its place
    /// when the mark is moved or resized.
    struct Link: Codable, Equatable {
        var target: UUID
        var anchor: CGPoint
    }

    var id = UUID()
    var tool: Tool
    /// Text tools: top-left of the text. Callout: `end` is the arrow tip.
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var fill: NSColor?
    var stroke: NSColor?
    var textColor: NSColor = .ink
    /// Body thickness of lines, arrows and pen strokes; a callout's arrow.
    var lineWidth: CGFloat = 8
    /// Thickness of whatever is painted in the border colour.
    var borderWidth: CGFloat = 4
    var fontSize: CGFloat = 44
    var fontFamily = ""
    var bold = true
    var hAlign = HAlign.left
    var vAlign = VAlign.middle
    /// Text boxes and callouts: a width the text wraps to and a minimum height, set by dragging
    /// the box's sides. `nil` means the box hugs its text.
    var boxWidth: CGFloat?
    var boxHeight: CGFloat?
    var text: String = ""
    var number: Int = 0
    /// What each end is snapped to. Lines and arrows snap at both ends, a callout at its tip (`end`).
    var startLink: Link?
    var endLink: Link?

    init(tool: Tool, at point: CGPoint, style: Style, scale: CGFloat) {
        self.tool = tool
        start = point
        end = point
        points = [point]
        apply(style, scale: scale)
    }

    mutating func apply(_ style: Style, scale: CGFloat) {
        fill = style.fill
        stroke = style.stroke
        textColor = style.text
        lineWidth = style.width * scale
        borderWidth = style.borderWidth * scale
        fontSize = (tool.usesFont ? style.fontSize : 10 + style.width * 3) * scale
        fontFamily = style.fontFamily
        bold = style.bold
        hAlign = style.hAlign
        vAlign = style.vAlign
    }

    func style(scale: CGFloat) -> Style {
        Style(fill: fill, stroke: stroke, text: textColor, width: lineWidth / scale, borderWidth: borderWidth / scale,
              fontFamily: fontFamily, fontSize: (fontSize / scale).rounded(), bold: bold,
              hAlign: hAlign, vAlign: vAlign)
    }

    // MARK: Geometry

    var rect: CGRect { CGRect(p1: start, p2: end) }

    private var font: NSFont { font(size: fontSize) }

    func font(size: CGFloat) -> NSFont {
        if !fontFamily.isEmpty,
           let custom = NSFontManager.shared.font(withFamily: fontFamily, traits: bold ? .boldFontMask : [],
                                                  weight: bold ? 9 : 5, size: size) {
            return custom
        }
        return .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private static let textDrawing: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = hAlign.textAlignment
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor,
                                                             .paragraphStyle: paragraph])
    }

    /// Size of the laid-out words: wrapped to `boxWidth` if the box has a set width.
    var textSize: CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: boxWidth ?? 100_000, height: 100_000), options: Self.textDrawing)
        return CGSize(width: max(ceil(measured.width), fontSize), height: ceil(measured.height))
    }

    /// The area text is laid out in: `start` is its top-left corner.
    var contentRect: CGRect {
        let text = textSize
        return CGRect(origin: start, size: CGSize(width: boxWidth ?? text.width,
                                                  height: max(boxHeight ?? 0, text.height)))
    }

    /// Where the words themselves sit inside `contentRect`, after vertical alignment.
    var textRect: CGRect {
        let content = contentRect, height = textSize.height
        let offset: CGFloat
        switch vAlign {
        case .top: offset = 0
        case .middle: offset = (content.height - height) / 2
        case .bottom: offset = content.height - height
        }
        return CGRect(x: content.minX, y: content.minY + offset, width: content.width, height: height)
    }

    /// Space between the text area and the box edge.
    var boxPadding: CGSize { CGSize(width: fontSize * 0.4, height: fontSize * 0.22) }

    /// The box around a text box or callout.
    var boxRect: CGRect {
        contentRect.insetBy(dx: -boxPadding.width, dy: -boxPadding.height)
    }

    private var stepRect: CGRect {
        let radius = fontSize * 0.85
        return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
    }


    /// Where a callout's arrow leaves its box, or nil if the tip is inside the box.
    private var pointerOrigin: CGPoint? {
        let box = boxRect
        guard !box.contains(end) else { return nil }
        let dx = end.x - box.midX, dy = end.y - box.midY
        let tx = dx == 0 ? CGFloat.infinity : (box.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (box.height / 2) / abs(dy)
        let t = min(tx, ty)
        return CGPoint(x: box.midX + dx * t, y: box.midY + dy * t)
    }

    var bounds: CGRect {
        switch tool {
        case .text:
            return boxRect
        case .callout:
            return boxRect.union(CGRect(origin: end, size: .zero).insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2))
        case .step:
            return stepRect
        case .pen:
            guard let first = points.first else { return .zero }
            return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -lineWidth, dy: -lineWidth)
        case .arrow, .line:
            return rect.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        default:
            return rect.insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2)
        }
    }

    // MARK: Snapping

    /// The outline that arrow and line ends can snap onto, for marks that have one.
    private var snapFrame: (rect: CGRect, isOval: Bool)? {
        switch tool {
        case .text, .callout: return (boxRect, false)
        case .rect, .highlight, .blur: return (rect, false)
        case .ellipse: return (rect, true)
        case .step: return (stepRect, true)
        default: return nil
        }
    }

    /// Closest point on this mark's outline to `p`.
    private func outlinePoint(nearest p: CGPoint) -> CGPoint? {
        guard let (r, isOval) = snapFrame, r.width > 0, r.height > 0 else { return nil }
        if isOval {
            let angle = atan2((p.y - r.midY) / (r.height / 2), (p.x - r.midX) / (r.width / 2))
            return CGPoint(x: r.midX + cos(angle) * r.width / 2, y: r.midY + sin(angle) * r.height / 2)
        }
        let inside = CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
        guard r.contains(p) else { return inside }
        // Inside the box: push out to the nearest side.
        let gaps = [p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y]
        switch gaps.firstIndex(of: gaps.min()!)! {
        case 0: return CGPoint(x: r.minX, y: p.y)
        case 1: return CGPoint(x: r.maxX, y: p.y)
        case 2: return CGPoint(x: p.x, y: r.minY)
        default: return CGPoint(x: p.x, y: r.maxY)
        }
    }

    /// Where a line end dragged to `p` should stick on this mark: a side midpoint or corner if
    /// one is close, otherwise the nearest spot on the outline; another line's end.
    func snapPoint(near p: CGPoint, tolerance: CGFloat) -> CGPoint? {
        func near(_ q: CGPoint) -> Bool { hypot(q.x - p.x, q.y - p.y) <= tolerance }
        if tool == .line || tool == .arrow {
            return [start, end].filter(near).min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }
        }
        guard let (r, isOval) = snapFrame else { return nil }
        var anchors = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                       CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        if !isOval {
            anchors += [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        }
        if let anchor = anchors.filter(near).min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }) {
            return anchor
        }
        return outlinePoint(nearest: p).flatMap { near($0) ? $0 : nil }
    }

    var linksStart: Bool { tool == .line || tool == .arrow }
    var linksEnd: Bool { linksStart || tool == .callout }

    /// The link that holds a line end at `p`, a point on this mark.
    func link(at p: CGPoint) -> Link? {
        if tool == .line || tool == .arrow {
            let nearerEnd = hypot(p.x - end.x, p.y - end.y) < hypot(p.x - start.x, p.y - start.y)
            return Link(target: id, anchor: CGPoint(x: nearerEnd ? 1 : 0, y: 0))
        }
        guard let r = snapFrame?.rect, r.width > 0, r.height > 0 else { return nil }
        return Link(target: id, anchor: CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height))
    }

    /// Where a link's anchor sits on this mark as it is now.
    func point(at anchor: CGPoint) -> CGPoint? {
        if tool == .line || tool == .arrow {
            return CGPoint(x: start.x + (end.x - start.x) * anchor.x, y: start.y + (end.y - start.y) * anchor.x)
        }
        guard let r = snapFrame?.rect else { return nil }
        return CGPoint(x: r.minX + r.width * anchor.x, y: r.minY + r.height * anchor.y)
    }

    /// The same mark for a capture with a different pixel density.
    func scaled(by factor: CGFloat) -> Annotation {
        guard factor != 1 else { return self }
        var copy = self
        func scale(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * factor, y: p.y * factor) }
        copy.start = scale(start)
        copy.end = scale(end)
        copy.points = points.map(scale)
        copy.lineWidth *= factor
        copy.borderWidth *= factor
        copy.fontSize *= factor
        copy.boxWidth = boxWidth.map { $0 * factor }
        copy.boxHeight = boxHeight.map { $0 * factor }
        return copy
    }

    /// Everything the mark paints, for working out whether it reaches past the image.
    var visualBounds: CGRect {
        switch tool {
        case .select, .crop: return .null
        case .rect, .ellipse: return stroke == nil ? rect : bounds
        case .highlight, .blur: return stroke == nil ? rect : bounds
        default: return bounds.insetBy(dx: -borderWidth, dy: -borderWidth)
        }
    }

    /// Too small to be an intentional mark.
    var isDegenerate: Bool {
        switch tool {
        case .text, .callout, .step: return false
        case .pen: return points.count < 2
        case .arrow, .line: return hypot(end.x - start.x, end.y - start.y) < 4
        default: return rect.width < 4 || rect.height < 4
        }
    }

    /// Drag points for reshaping: line ends, box corners, or a callout's arrow tip.
    var handles: [(kind: HandleKind, point: CGPoint)] {
        switch tool {
        case .line, .arrow:
            return [(.start, start), (.end, end)]
        case .text, .callout:
            let box = boxRect
            let sides: [(kind: HandleKind, point: CGPoint)] = [
                (.scale, CGPoint(x: box.maxX, y: box.maxY)),
                (.edge(0), CGPoint(x: box.minX, y: box.midY)), (.edge(1), CGPoint(x: box.midX, y: box.minY)),
                (.edge(2), CGPoint(x: box.maxX, y: box.midY)), (.edge(3), CGPoint(x: box.midX, y: box.maxY)),
            ]
            return tool == .callout ? [(.end, end)] + sides : sides
        case .rect, .ellipse, .highlight, .blur:
            let r = rect
            return [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                    (.corner(2), CGPoint(x: r.maxX, y: r.maxY)), (.corner(3), CGPoint(x: r.minX, y: r.maxY))]
        default:
            return []
        }
    }

    /// Marks grab by their visible parts. `interior` also makes the empty inside of an unfilled
    /// box or oval count.
    func hitTest(_ p: CGPoint, tolerance: CGFloat, interior: Bool) -> Bool {
        let band = (tool == .rect || tool == .ellipse ? borderWidth : lineWidth) / 2 + tolerance
        switch tool {
        case .line:
            return Self.distance(p, start, end) <= band
        case .arrow:
            return Self.distance(p, start, end) <= band + lineWidth
        case .pen:
            return zip(points, points.dropFirst()).contains { Self.distance(p, $0, $1) <= band }
        case .rect, .highlight, .blur:
            guard rect.insetBy(dx: -band, dy: -band).contains(p) else { return false }
            // Highlights and blurs are solid to the eye, so their whole area grabs.
            return interior || tool != .rect || fill != nil || !rect.insetBy(dx: band, dy: band).contains(p)
        case .ellipse:
            let r = rect, a = r.width / 2, b = r.height / 2
            func level(_ ra: CGFloat, _ rb: CGFloat) -> CGFloat {
                pow((p.x - r.midX) / ra, 2) + pow((p.y - r.midY) / rb, 2)
            }
            guard level(a + band, b + band) <= 1 else { return false }
            return interior || fill != nil || a <= band || b <= band || level(a - band, b - band) >= 1
        case .text, .step:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .callout:
            if boxRect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return true }
            guard let origin = pointerOrigin else { return false }
            return Self.distance(p, origin, end) <= band + lineWidth
        case .select, .crop:
            return false
        }
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    // MARK: Drawing

    /// Draws into a flipped (top-left origin) context whose NSGraphicsContext is current.
    /// `showsText: false` leaves the words out while a text field is editing them in place.
    func draw(in ctx: CGContext, base: CGImage, showsText: Bool = true) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch tool {
        case .select, .crop:
            break
        case .line, .arrow, .pen:
            drawLineShape(ctx)
        case .rect:
            ctx.setLineJoin(.miter)
            paint(ctx, CGPath(rect: rect, transform: nil), borderWidth: borderWidth)
        case .ellipse:
            paint(ctx, CGPath(ellipseIn: rect, transform: nil), borderWidth: borderWidth)
        case .highlight:
            if let fill {
                ctx.saveGState()
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(fill.withAlphaComponent(0.4).cgColor)
                ctx.fill(rect)
                ctx.restoreGState()
            }
            paint(ctx, CGPath(rect: rect, transform: nil), borderWidth: borderWidth, fills: false)
        case .blur:
            let imageBounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
            let r = rect.integral.intersection(imageBounds)
            if let pixels = Self.pixelated(base, rect: r) {
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.drawFlipped(pixels, in: r)
                ctx.restoreGState()
            }
            paint(ctx, CGPath(rect: rect, transform: nil), borderWidth: borderWidth, fills: false)
        case .text:
            drawTextBox(ctx, showsText: showsText)
        case .callout:
            if let origin = pointerOrigin {
                let color = (stroke ?? fill ?? textColor).cgColor
                Self.traceArrow(ctx, from: origin, to: end, width: lineWidth, expand: 0, color: color)
            }
            drawTextBox(ctx, showsText: showsText)
        case .step:
            let circle = CGPath(ellipseIn: stepRect, transform: nil)
            if let fill {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: fontSize * 0.15, color: NSColor.black.withAlphaComponent(0.35).cgColor)
                ctx.addPath(circle)
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            paint(ctx, circle, borderWidth: borderWidth, fills: false)
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: textColor,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2))
        }
    }

    private func paint(_ ctx: CGContext, _ path: CGPath, borderWidth: CGFloat, fills: Bool = true) {
        if fills, let fill {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }
    }

    private func drawTextBox(_ ctx: CGContext, showsText: Bool) {
        let radius = fontSize * 0.3
        let box = boxRect
        let path = CGPath(roundedRect: box, cornerWidth: min(radius, box.width / 2),
                          cornerHeight: min(radius, box.height / 2), transform: nil)
        paint(ctx, path, borderWidth: borderWidth)
        if showsText { attributedText.draw(with: textRect, options: Self.textDrawing) }
    }

    /// Lines, arrows and pen strokes: `fill` is the body, `stroke` an outline around it.
    /// Border with no fill gives a hollow shape.
    private func drawLineShape(_ ctx: CGContext) {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let stroke { traceLineShape(ctx, expand: borderWidth, color: stroke.cgColor) }
        if let fill {
            traceLineShape(ctx, expand: 0, color: fill.cgColor)
        } else if stroke != nil {
            ctx.setBlendMode(.clear)
            traceLineShape(ctx, expand: 0, color: NSColor.black.cgColor)
            ctx.setBlendMode(.normal)
        }
        ctx.endTransparencyLayer()
    }

    private func traceLineShape(_ ctx: CGContext, expand: CGFloat, color: CGColor) {
        switch tool {
        case .arrow:
            Self.traceArrow(ctx, from: start, to: end, width: lineWidth, expand: expand, color: color)
        case .pen:
            guard points.count > 1 else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth + expand * 2)
            ctx.move(to: points[0])
            for i in 1..<points.count - 1 {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                ctx.addQuadCurve(to: mid, control: points[i])
            }
            ctx.addLine(to: points[points.count - 1])
            ctx.strokePath()
        default:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth + expand * 2)
            ctx.strokeLineSegments(between: [start, end])
        }
    }

    /// `expand` grows the whole silhouette outward, for drawing an outline behind the body.
    private static func traceArrow(_ ctx: CGContext, from start: CGPoint, to end: CGPoint, width: CGFloat,
                                   expand: CGFloat, color: CGColor) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let head = min(width * 4.5, length * 0.9)
        let halfWidth = head * 0.45
        let neck = CGPoint(x: end.x - ux * head, y: end.y - uy * head)

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width + expand * 2)
        ctx.strokeLineSegments(between: [start, CGPoint(x: neck.x + ux * width / 2, y: neck.y + uy * width / 2)])

        let headPath = CGMutablePath()
        headPath.move(to: end)
        headPath.addLine(to: CGPoint(x: neck.x - uy * halfWidth, y: neck.y + ux * halfWidth))
        headPath.addLine(to: CGPoint(x: neck.x + uy * halfWidth, y: neck.y - ux * halfWidth))
        headPath.closeSubpath()
        ctx.addPath(headPath)
        ctx.fillPath()
        if expand > 0 {
            ctx.setLineWidth(expand * 2)
            ctx.addPath(headPath)
            ctx.strokePath()
        }
    }

    private static func pixelated(_ base: CGImage, rect: CGRect) -> CGImage? {
        guard rect.width >= 2, rect.height >= 2, let crop = base.cropping(to: rect) else { return nil }
        let block = min(max(min(rect.width, rect.height) / 10, 8), 28)
        let w = max(1, Int(rect.width / block)), h = max(1, Int(rect.height / block))
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return small.makeImage()
    }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}

extension CGContext {
    /// Draws an image upright in a context whose y axis points down.
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}
