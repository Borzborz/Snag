import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the editor window, the open document and the capture library strip.
final class EditorController: NSObject, ObservableObject, NSWindowDelegate {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        .ink,
        .paper,
    ]
    static let widths: [CGFloat] = [2, 4, 7]

    @Published var tool: Tool = .arrow {
        didSet {
            canvas.toolChanged()
            if canvas.selectedAnnotation == nil { selectionChanged(nil) }
        }
    }
    /// What the style panel shows: the selected mark's style, or the current tool's.
    @Published private(set) var style = Style.standard(for: .arrow)
    @Published private(set) var styleTool: Tool = .arrow
    @Published private(set) var hasSelection = false
    /// Whether the selected mark touches marks it could be snapped to, and whether it is snapped to any.
    @Published private(set) var canSnap = false
    @Published private(set) var canUnsnap = false
    /// Each tool remembers the style last used with it.
    private var toolStyles: [Tool: Style] = [:]
    /// What to do with marks that reach past the image. Remembered between launches.
    @Published var outsideMode = OutsideMode(rawValue: UserDefaults.standard.string(forKey: "outsideMode") ?? "")
        ?? .expandWhite {
        didSet {
            UserDefaults.standard.set(outsideMode.rawValue, forKey: "outsideMode")
            canvas.doc?.dirty = true
            documentChanged()
        }
    }
    /// Line and arrow ends dropped on another mark snap onto it, and the two then move as one.
    /// Remembered between launches.
    @Published var snapEnabled = UserDefaults.standard.object(forKey: "snapEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snapEnabled, forKey: "snapEnabled") }
    }
    /// The magnification `zoomToFit` last chose, to tell whether the user has zoomed by hand since.
    private var fittedMagnification: CGFloat?

    /// Common families first; the full list follows in the font menu.
    static let favouriteFonts: [String] = ["Helvetica Neue", "Arial", "Avenir Next", "Futura", "Gill Sans", "Georgia",
                                           "Times New Roman", "Courier New", "Menlo", "American Typewriter",
                                           "Marker Felt", "Chalkboard SE", "Impact"]
        .filter(NSFontManager.shared.availableFontFamilies.contains)
    static let otherFonts: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") && !favouriteFonts.contains($0) }
    @Published var items: [LibraryItem] = []
    @Published var currentURL: URL?
    @Published var canUndo = false
    @Published var canRedo = false

    private static let frameName = "SnagEditor"

    let window: NSWindow
    let scrollView = NSScrollView()
    let canvas = CanvasView()
    private var docs: [URL: CaptureDocument] = [:]
    /// File writes happen here, in order, so saving never stalls drawing.
    private let saveQueue = DispatchQueue(label: "snag.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: true)
        super.init()

        canvas.controller = self
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = NSColor(white: 0.13, alpha: 1)

        window.title = "Snag"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 620)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(controller: self))
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Fill the screen by default; after that, remember however the user sized it.
        if !window.setFrameUsingName(Self.frameName), let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            window.setFrame(visible, display: false)
        }
        window.setFrameAutosaveName(Self.frameName)
        reloadItems()
    }

    // MARK: Opening

    /// A fresh capture: save it, copy it, show it. Pasted images are already on the clipboard.
    func open(image: CGImage, scale: CGFloat, copy: Bool = true) {
        flush()
        let url = Library.newURL()
        Library.write(image, scale: scale, to: url)
        if copy { Clipboard.copy(image, scale: scale) }
        let doc = CaptureDocument(base: image, scale: scale, url: url)
        docs[url] = doc
        show(doc)
        reloadItems()
    }

    func open(url: URL) {
        guard url != currentURL else { return }
        flush()
        if let doc = docs[url] {
            show(doc)
        } else if let (image, scale) = Library.read(url) {
            // Captures with saved marks reopen as the clean image plus those marks, still editable.
            let edits = EditStore.load(for: url)
            let doc = CaptureDocument(base: edits?.base ?? image, scale: scale, url: url)
            doc.annotations = edits?.annotations ?? []
            doc.savedBase = edits?.base
            docs[url] = doc
            show(doc)
        }
    }

    /// An empty editor, ready for an image to be pasted in.
    @objc func newSession(_ sender: Any? = nil) {
        flush()
        canvas.doc = nil
        currentURL = nil
        window.title = "New Session"
        updateUndoState()
        present()
    }

    /// ⌘V: copied marks go onto the open capture; a copied image becomes a new capture.
    func paste(at point: CGPoint? = nil) {
        if canvas.doc != nil, let clip = Clipboard.marks() {
            canvas.paste(marks: clip.annotations, sourceScale: clip.scale, at: point)
        } else if let (image, scale) = Clipboard.image() {
            open(image: image, scale: scale, copy: false)
        } else {
            Toast.show("Nothing to paste — copy an image first")
        }
    }

    /// Reached through the window when the canvas itself isn't first responder.
    @objc func paste(_ sender: Any?) { paste() }

    func showWindow() {
        if canvas.doc == nil, let first = items.first { open(url: first.url) }
        present()
    }

    private func show(_ doc: CaptureDocument) {
        // Keep edit history for recent captures only.
        if docs.count > 12, let stale = docs.keys.first(where: { $0 != doc.url && docs[$0]?.dirty == false }) {
            docs[stale] = nil
        }
        canvas.doc = doc
        currentURL = doc.url
        window.title = doc.url.deletingPathExtension().lastPathComponent
        updateUndoState()

        present()
        DispatchQueue.main.async { self.zoomToFit() }
    }

    private func present() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
    }

    func zoomToFit() {
        let available = scrollView.frame.size
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        scrollView.magnification = min(1, available.width / size.width, available.height / size.height)
        fittedMagnification = scrollView.magnification
    }

    // MARK: Style

    func style(for tool: Tool) -> Style {
        toolStyles[tool] ?? .standard(for: tool)
    }

    func selectionChanged(_ annotation: Annotation?) {
        hasSelection = annotation != nil
        if let annotation, let scale = canvas.doc?.scale {
            styleTool = annotation.tool
            style = annotation.style(scale: scale)
        } else {
            styleTool = tool
            style = style(for: tool)
        }
        updateSnapState()
    }

    private func updateSnapState() {
        canSnap = canvas.canSnapSelection
        canUnsnap = canvas.selectionIsSnapped
    }

    func snapSelection() { canvas.snapSelected() }
    func unsnapSelection() { canvas.unsnapSelected() }

    func updateStyle(_ change: (inout Style) -> Void) {
        var next = style
        change(&next)
        guard next != style else { return }
        if next.fill == nil, next.stroke == nil, !styleTool.allowsNoColor {
            Toast.show("\(styleTool.title) needs a fill or a border colour")
            return
        }
        style = next
        toolStyles[styleTool] = next
        canvas.styleChanged()
    }

    // MARK: Document lifecycle

    func documentChanged(resized: Bool = false) {
        canvas.doc?.resolveLinks()
        updateUndoState()
        updateSnapState()
        // The picture may have grown or shrunk around marks outside the image. Refit it,
        // unless the user has zoomed by hand.
        let grew = canvas.syncSize()
        let stillFitted = fittedMagnification.map { abs($0 - scrollView.magnification) < 0.001 } ?? true
        if resized || (grew && stillFitted) { DispatchQueue.main.async { self.zoomToFit() } }
        scheduleSave()
    }

    /// Saves shortly after the last change, so nothing is lost if the app is quit or killed.
    private func scheduleSave() {
        pendingSave?.cancel()
        guard let doc = canvas.doc, doc.dirty else { return }
        let work = DispatchWorkItem { [weak self] in self?.save(doc) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes the finished picture to the library and the editable marks to the edit store.
    private func save(_ doc: CaptureDocument) {
        guard doc.dirty else { return }
        doc.dirty = false
        let image = doc.render(outside: outsideMode)
        let annotations = doc.annotations, base = doc.base, url = doc.url, scale = doc.scale
        let baseChanged = doc.savedBase !== base
        doc.savedBase = annotations.isEmpty ? nil : base
        saveQueue.async {
            Library.write(image, scale: scale, to: url)
            if annotations.isEmpty {
                EditStore.remove(for: url)
            } else {
                EditStore.save(base: baseChanged ? base : nil, annotations: annotations, scale: scale, for: url)
            }
            DispatchQueue.main.async { [weak self] in self?.reloadItems() }
        }
    }

    private func updateUndoState() {
        canUndo = canvas.doc?.canUndo ?? false
        canRedo = canvas.doc?.canRedo ?? false
    }

    /// Saves pending edits of the open capture now. `wait` blocks until they are on disk (for quitting).
    func flush(wait: Bool = false) {
        canvas.commitText()
        pendingSave?.cancel()
        if let doc = canvas.doc { save(doc) }
        if wait { saveQueue.sync {} }
    }

    func reloadItems() {
        items = Library.list().compactMap { url in
            Library.thumbnail(for: url).map { LibraryItem(url: url, thumb: $0) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        flush()
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Actions

    /// Returns the selected text box or callout to hugging its text.
    func fitTextBox() { canvas.fitSelectedBox() }

    func undo() { canvas.undo(nil) }
    func redo() { canvas.redo(nil) }

    func copyImage() {
        canvas.commitText()
        guard let doc = canvas.doc else { return }
        Clipboard.copy(doc.render(outside: outsideMode), scale: doc.scale)
        Toast.show("Copied to clipboard")
    }

    func copyText() {
        guard let doc = canvas.doc else { return }
        let image = doc.base
        DispatchQueue.global(qos: .userInitiated).async {
            let text = OCR.recognize(image)
            DispatchQueue.main.async {
                if text.isEmpty {
                    Toast.show("No text found")
                } else {
                    Clipboard.copy(text)
                    Toast.show("Text copied")
                }
            }
        }
    }

    @objc func saveAs(_ sender: Any?) {
        canvas.commitText()
        guard let doc = canvas.doc else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = doc.url.lastPathComponent
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let type: UTType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
            let image = doc.render(outside: self.outsideMode, opaque: type == .jpeg)
            if !Library.write(image, scale: doc.scale, to: url, type: type) {
                Toast.show("Couldn’t save the image")
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func trash(_ url: URL) {
        if url == currentURL { pendingSave?.cancel() }
        saveQueue.sync {} // let any write to this file finish first
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        EditStore.remove(for: url)
        docs[url] = nil
        reloadItems()
        guard url == currentURL else { return }
        canvas.doc = nil
        currentURL = nil
        window.title = "Snag"
        updateUndoState()
        if let next = items.first { open(url: next.url) }
    }
}

/// Keeps the canvas centred when it is smaller than the visible area.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: - SwiftUI chrome

struct EditorView: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    CanvasHost(scrollView: controller.scrollView)
                    if controller.currentURL == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "viewfinder").font(.system(size: 40, weight: .light))
                            Text("Empty session").font(.title3)
                            Text("Press ⌘V to paste an image, or ⌃⇧C anywhere to capture.")
                                .foregroundStyle(.secondary)
                            Button("Paste Image") { controller.paste() }
                                .controlSize(.large)
                                .padding(.top, 4)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }
                }
                if !controller.items.isEmpty {
                    Divider()
                    strip
                }
            }
            Divider()
            sidebar
                .frame(width: EditorView.sidebarWidth)
                .disabled(controller.currentURL == nil)
        }
    }

    static let sidebarWidth: CGFloat = 232

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    heading("Tools")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(Tool.allCases) { tool in
                            let isOn = controller.tool == tool
                            Button { controller.tool = tool } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tool.symbol)
                                        .font(.system(size: 19, weight: .medium))
                                        .frame(height: 22)
                                    Text(tool.title)
                                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                                }
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(isOn ? Color.white : Color.primary)
                                .background(isOn ? Color.accentColor : Color.primary.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(tool.hint) (\(String(tool.key).uppercased()))")
                        }
                    }
                    Text(controller.tool.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.tool != .select && controller.tool != .crop {
                        Text("Drag any mark to move it, whichever tool is on.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    stylePanel

                    Toggle("Snap arrows to objects", isOn: $controller.snapEnabled)
                        .font(.system(size: 12))
                        .controlSize(.regular)
                        .padding(.top, 6)
                        .help("Drop a line or arrow end on a box, callout or other mark and the two snap together and move as one. Hold ⌘ while dragging to switch it off once; hold ⌥ to move one snapped mark on its own.")
                    HStack(spacing: 6) {
                        Button { controller.snapSelection() } label: {
                            Label("Snap", systemImage: "link").frame(maxWidth: .infinity)
                        }
                        .disabled(!controller.canSnap)
                        .help("Snap the selected mark to the marks it touches, so they move as one")
                        Button { controller.unsnapSelection() } label: {
                            Label("Unsnap", systemImage: "personalhotspot.slash").frame(maxWidth: .infinity)
                        }
                        .disabled(!controller.canUnsnap)
                        .help("Separate the selected mark from the marks it is snapped to")
                    }
                    .controlSize(.regular)

                    heading("Marks past the image edge")
                    Picker("Marks past the image edge", selection: $controller.outsideMode) {
                        ForEach(OutsideMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.regular)
                    .help("What the saved and copied picture does with marks that reach outside the capture")
                }
                .padding(12)
            }
            Divider()
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Button { controller.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .disabled(!controller.canUndo).help("Undo (⌘Z)")
                    Button { controller.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward").frame(maxWidth: .infinity)
                    }
                    .disabled(!controller.canRedo).help("Redo (⇧⌘Z)")
                }
                Button { controller.copyText() } label: {
                    Label("Copy Text", systemImage: "text.viewfinder").frame(maxWidth: .infinity)
                }
                .help("Recognise the text in this capture and copy it")
                Button { controller.saveAs(nil) } label: {
                    Label("Save As…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                Button { controller.copyImage() } label: {
                    Label("Copy Image", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Copy the annotated image (⌘C)")
            }
            .padding(12)
        }
        .controlSize(.large)
    }

    /// Fill / border / text colours and size for the selected mark, or for the next one drawn.
    private var stylePanel: some View {
        let tool = controller.styleTool
        let style = controller.style
        let title = !tool.hasStyle ? "Style" : controller.hasSelection ? "Selected \(tool.title)" : "\(tool.title) style"
        return VStack(alignment: .leading, spacing: 8) {
            heading(title)
            colorRow("Fill", style.fill, allowsNone: true) { color in controller.updateStyle { $0.fill = color } }
                .disabled(!tool.usesFill)
                .opacity(tool.usesFill ? 1 : 0.35)
            colorRow("Border", style.stroke, allowsNone: true) { color in controller.updateStyle { $0.stroke = color } }
            borderSizeRow(style)
                .disabled(style.stroke == nil)
                .opacity(style.stroke == nil ? 0.35 : 1)
            if tool.usesText {
                colorRow("Text", style.text, allowsNone: false) { color in
                    if let color { controller.updateStyle { $0.text = color } }
                }
            }
            if tool.usesFont { fontControls(style) }
            if tool.usesThickness || !tool.hasStyle {
                thicknessRow(style, title: tool == .step ? "Size" : tool == .callout ? "Arrow thickness" : "Thickness")
            }
        }
        .disabled(!tool.hasStyle)
        .opacity(tool.hasStyle ? 1 : 0.35)
    }

    /// How thick the border (outline) is, in points.
    private func borderSizeRow(_ style: Style) -> some View {
        HStack(spacing: 6) {
            Text("Border size")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { controller.updateStyle { $0.borderWidth = max($0.borderWidth - 1, Style.minBorderWidth) } } label: {
                Image(systemName: "minus").frame(width: 14, height: 14)
            }
            .help("Thinner border")
            TextField("Border size", value: Binding(get: { Double(style.borderWidth) }, set: { size in
                controller.updateStyle {
                    $0.borderWidth = min(max(CGFloat(size), Style.minBorderWidth), Style.maxBorderWidth)
                }
            }), format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .help("Border thickness in points")
            Button { controller.updateStyle { $0.borderWidth = min($0.borderWidth + 1, Style.maxBorderWidth) } } label: {
                Image(systemName: "plus").frame(width: 14, height: 14)
            }
            .help("Thicker border")
        }
        .controlSize(.regular)
    }

    private func thicknessRow(_ style: Style, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(EditorController.widths, id: \.self) { width in
                    let isOn = style.width == width
                    Button { controller.updateStyle { $0.width = width } } label: {
                        Capsule()
                            .fill(isOn ? Color.white : Color.primary)
                            .frame(width: 30, height: width + 1)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(isOn ? Color.accentColor : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Font family, size and bold for text boxes and callouts.
    private func fontControls(_ style: Style) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Font")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("Font", selection: Binding(get: { style.fontFamily },
                                              set: { family in controller.updateStyle { $0.fontFamily = family } })) {
                Text("System").tag("")
                Divider()
                ForEach(EditorController.favouriteFonts, id: \.self) { Text($0).tag($0) }
                Divider()
                ForEach(EditorController.otherFonts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.regular)

            HStack(spacing: 6) {
                Button { controller.updateStyle { $0.fontSize = max($0.fontSize - 2, Style.minFontSize) } } label: {
                    Image(systemName: "textformat.size.smaller").frame(width: 22)
                }
                .help("Smaller text")
                TextField("Size", value: Binding(get: { Double(style.fontSize) }, set: { size in
                    controller.updateStyle { $0.fontSize = min(max(CGFloat(size), Style.minFontSize), Style.maxFontSize) }
                }), format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .help("Text size in points")
                Button { controller.updateStyle { $0.fontSize = min($0.fontSize + 2, Style.maxFontSize) } } label: {
                    Image(systemName: "textformat.size.larger").frame(width: 22)
                }
                .help("Larger text")
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { style.bold }, set: { bold in controller.updateStyle { $0.bold = bold } })) {
                    Image(systemName: "bold").frame(width: 18)
                }
                .toggleStyle(.button)
                .help("Bold")
            }
            .controlSize(.regular)

            Text("Text position in box")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            HStack(spacing: 8) {
                Picker("Horizontal", selection: Binding(get: { style.hAlign },
                                                        set: { align in controller.updateStyle { $0.hAlign = align } })) {
                    ForEach(HAlign.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
                }
                .help("Left, centre or right")
                Picker("Vertical", selection: Binding(get: { style.vAlign },
                                                      set: { align in controller.updateStyle { $0.vAlign = align } })) {
                    ForEach(VAlign.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
                }
                .help("Top, middle or bottom")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)

            Button { controller.fitTextBox() } label: {
                Label("Fit box to text", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .disabled(!controller.hasSelection)
            .help("Undo any width or height set by dragging the box’s sides")
        }
    }

    private func colorRow(_ title: String, _ selection: NSColor?, allowsNone: Bool,
                          set: @escaping (NSColor?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                if allowsNone { swatch(nil, isOn: selection == nil, set: set) }
                ForEach(Array(EditorController.palette.enumerated()), id: \.offset) { _, color in
                    swatch(color, isOn: selection == color, set: set)
                }
            }
        }
    }

    /// `nil` is the "no colour" swatch: white with a red slash.
    private func swatch(_ color: NSColor?, isOn: Bool, set: @escaping (NSColor?) -> Void) -> some View {
        Button { set(color) } label: {
            ZStack {
                Circle().fill(Color(nsColor: color ?? .white))
                if color == nil {
                    Rectangle().fill(Color.red).frame(width: 1.5, height: 22).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
            .padding(3)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isOn ? 2 : 0))
            .frame(width: 23, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color == nil ? "No colour" : "")
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(controller.items) { item in
                    Image(nsImage: item.thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(item.url == controller.currentURL ? Color.accentColor : .secondary.opacity(0.3),
                                          lineWidth: item.url == controller.currentURL ? 2 : 0.5))
                        .onTapGesture { controller.open(url: item.url) }
                        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                        .contextMenu {
                            Button("Show in Finder") { controller.reveal(item.url) }
                            Button("Move to Trash") { controller.trash(item.url) }
                        }
                        .help(item.url.lastPathComponent)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 76)
    }
}

private struct CanvasHost: NSViewRepresentable {
    let scrollView: NSScrollView
    func makeNSView(context: Context) -> NSScrollView { scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

// MARK: - Toast

enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 36, height: label.frame.height + 20)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: 18, y: 10))
        effect.addSubview(label)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = effect
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 110))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }
}
