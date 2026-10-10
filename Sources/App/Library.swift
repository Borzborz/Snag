import AppKit
import ImageIO
import UniformTypeIdentifiers

struct LibraryItem: Identifiable {
    let url: URL
    let thumb: NSImage
    var id: URL { url }
}

/// Captures are plain PNG files in ~/Pictures/Snag.
enum Library {
    static let folder: URL = {
        let url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snag", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var thumbCache: [String: NSImage] = [:]

    static func newURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Capture \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(stem).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) (\(n)).png")
            n += 1
        }
        return url
    }

    @discardableResult
    static func write(_ image: CGImage, scale: CGFloat, to url: URL, type: UTType = .png) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        let dpi = 72 * scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func read(_ url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return (image, max(1, CGFloat(dpi / 72).rounded()))
    }

    /// Newest first.
    static func list(limit: Int = 40) -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: .skipsHiddenFiles)) ?? []
        return urls
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func thumbnail(for url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let key = "\(url.path)|\(modified.timeIntervalSince1970)"
        if let cached = thumbCache[key] { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        thumbCache[key] = image
        return image
    }
}

enum Clipboard {
    static func copy(_ image: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
    }

    private static let marksType = NSPasteboard.PasteboardType("com.alborz.snag.marks")

    static func copy(marks: [Annotation], scale: CGFloat) {
        guard let data = EditStore.encode(marks, scale: scale) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: marksType)
    }

    static func marks() -> (annotations: [Annotation], scale: CGFloat)? {
        NSPasteboard.general.data(forType: marksType).flatMap(EditStore.decode)
    }

    static var hasMarks: Bool { NSPasteboard.general.data(forType: marksType) != nil }

    /// An image on the clipboard: a copied picture, or a copied image file.
    static func image() -> (image: CGImage, scale: CGFloat)? {
        let pasteboard = NSPasteboard.general
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let file = (pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL])?.first,
           let read = Library.read(file) {
            return read
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), let rep = NSBitmapImageRep(data: data),
                  let image = rep.cgImage else { continue }
            // Retina screenshots carry a point size half their pixel size.
            let scale = rep.size.width > 0 ? max(1, (CGFloat(rep.pixelsWide) / rep.size.width).rounded()) : 1
            return (image, scale)
        }
        return nil
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
