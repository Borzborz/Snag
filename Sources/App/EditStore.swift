import AppKit

/// Keeps each capture's marks editable across switches and relaunches.
/// The PNG in the library is the finished picture; alongside it, in Application Support,
/// lives the untouched image and the list of marks drawn on it.
enum EditStore {
    private static let folder: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snag/Edits", isDirectory: true)
    }()

    private static func directory(for url: URL) -> URL {
        folder.appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    /// Pass `base` only when the underlying image is new or has changed; it is the slow part.
    static func save(base: CGImage?, annotations: [Annotation], scale: CGFloat, for url: URL) {
        let directory = directory(for: url)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let base { Library.write(base, scale: scale, to: directory.appendingPathComponent("base.png")) }
        if let data = try? JSONEncoder().encode(annotations.map(StoredAnnotation.init)) {
            try? data.write(to: directory.appendingPathComponent("marks.json"), options: .atomic)
        }
    }

    static func load(for url: URL) -> (base: CGImage, annotations: [Annotation])? {
        let directory = directory(for: url)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("marks.json")),
              let stored = try? JSONDecoder().decode([StoredAnnotation].self, from: data),
              let base = Library.read(directory.appendingPathComponent("base.png"))?.image else { return nil }
        return (base, stored.map(Annotation.init))
    }

    static func remove(for url: URL) {
        try? FileManager.default.removeItem(at: directory(for: url))
    }

    // Copy and paste of marks uses the same encoding, plus the pixel density they were drawn at.

    static func encode(_ annotations: [Annotation], scale: CGFloat) -> Data? {
        try? JSONEncoder().encode(StoredClip(scale: scale, marks: annotations.map(StoredAnnotation.init)))
    }

    static func decode(_ data: Data) -> (annotations: [Annotation], scale: CGFloat)? {
        guard let clip = try? JSONDecoder().decode(StoredClip.self, from: data) else { return nil }
        return (clip.marks.map(Annotation.init), clip.scale)
    }
}

private struct StoredClip: Codable {
    var scale: CGFloat
    var marks: [StoredAnnotation]
}

private struct StoredColor: Codable {
    var r, g, b, a: CGFloat

    init?(_ color: NSColor?) {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        (r, g, b, a) = (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

private struct StoredAnnotation: Codable {
    /// Optional so captures saved before marks could be snapped together still load.
    var id: UUID?
    var startLink: Annotation.Link?
    var endLink: Annotation.Link?
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var fill: StoredColor?
    var stroke: StoredColor?
    var textColor: StoredColor?
    var lineWidth: CGFloat
    var borderWidth: CGFloat
    var fontSize: CGFloat
    var fontFamily: String
    var bold: Bool
    var hAlign: HAlign
    var vAlign: VAlign
    var boxWidth: CGFloat?
    var boxHeight: CGFloat?
    var text: String
    var number: Int

    init(_ a: Annotation) {
        id = a.id
        startLink = a.startLink
        endLink = a.endLink
        tool = a.tool
        start = a.start
        end = a.end
        points = a.points
        fill = StoredColor(a.fill)
        stroke = StoredColor(a.stroke)
        textColor = StoredColor(a.textColor)
        lineWidth = a.lineWidth
        borderWidth = a.borderWidth
        fontSize = a.fontSize
        fontFamily = a.fontFamily
        bold = a.bold
        hAlign = a.hAlign
        vAlign = a.vAlign
        boxWidth = a.boxWidth
        boxHeight = a.boxHeight
        text = a.text
        number = a.number
    }
}

private extension Annotation {
    init(_ s: StoredAnnotation) {
        self.init(tool: s.tool, at: s.start, style: .standard(for: s.tool), scale: 1)
        if let id = s.id { self.id = id }
        startLink = s.startLink
        endLink = s.endLink
        end = s.end
        points = s.points
        fill = s.fill?.color
        stroke = s.stroke?.color
        textColor = s.textColor?.color ?? .ink
        lineWidth = s.lineWidth
        borderWidth = s.borderWidth
        fontSize = s.fontSize
        fontFamily = s.fontFamily
        bold = s.bold
        hAlign = s.hAlign
        vAlign = s.vAlign
        boxWidth = s.boxWidth
        boxHeight = s.boxHeight
        text = s.text
        number = s.number
    }
}
