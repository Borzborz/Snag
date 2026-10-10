import AppKit
import ScreenCaptureKit
import Vision

/// A frozen frame of one display.
struct Shot {
    let screen: NSScreen
    let image: CGImage
    /// Pixels per point.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

enum ScreenCapturer {
    enum CaptureError: LocalizedError {
        case noDisplays
        var errorDescription: String? { "No displays could be captured." }
    }

    @MainActor
    static func captureAll() async throws -> [Shot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [Shot] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(Shot(screen: screen, image: image))
        }
        guard !shots.isEmpty else { throw CaptureError.noDisplays }
        return shots
    }
}

enum OCR {
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
