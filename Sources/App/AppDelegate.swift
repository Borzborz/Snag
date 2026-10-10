import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Mode { case region, fullScreen, text }

    private var statusItem: NSStatusItem!
    private let editor = EditorController()
    private var session: SelectionSession?
    private var busy = false
    private var loginItem: NSMenuItem!
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildMainMenu()
        quitOnTerminationSignal()

        let mods = controlKey | shiftKey
        let registered = [
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_C, modifiers: mods) { [weak self] in self?.capture(.region) },
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_F, modifiers: mods) { [weak self] in self?.capture(.fullScreen) },
            HotKeyCenter.shared.register(keyCode: kVK_ANSI_T, modifiers: mods) { [weak self] in self?.capture(.text) },
        ]
        if registered.contains(false) {
            Toast.show("Some Snag shortcuts are already used by another app")
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editor.showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        editor.flush(wait: true)
    }

    /// Quit cleanly on `kill`, so edits are saved first.
    private func quitOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    // MARK: Capture

    func capture(_ mode: Mode) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }
        busy = true
        let editorWasVisible = editor.window.isVisible
        if editorWasVisible { editor.window.orderOut(nil) }

        Task { @MainActor in
            // Let the editor window / status menu leave the screen before the freeze frame.
            try? await Task.sleep(nanoseconds: editorWasVisible ? 280_000_000 : 80_000_000)
            do {
                let shots = try await ScreenCapturer.captureAll()
                if mode == .fullScreen {
                    let mouse = NSEvent.mouseLocation
                    let shot = shots.first { $0.screen.frame.contains(mouse) } ?? shots[0]
                    finish(mode, .init(image: shot.image, scale: shot.scale), editorWasVisible)
                } else {
                    let session = SelectionSession(shots: shots) { [weak self] result in
                        self?.session = nil
                        self?.finish(mode, result, editorWasVisible)
                    }
                    self.session = session
                    session.begin()
                }
            } catch {
                busy = false
                if editorWasVisible { editor.window.makeKeyAndOrderFront(nil) }
                let alert = NSAlert()
                alert.messageText = "Snag couldn’t capture the screen"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func finish(_ mode: Mode, _ result: SelectionSession.Result?, _ editorWasVisible: Bool) {
        busy = false
        guard let result else {
            if editorWasVisible { editor.window.makeKeyAndOrderFront(nil) }
            return
        }
        if mode == .text {
            if editorWasVisible { editor.window.makeKeyAndOrderFront(nil) }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = OCR.recognize(result.image)
                DispatchQueue.main.async {
                    if text.isEmpty {
                        Toast.show("No text found")
                    } else {
                        Clipboard.copy(text)
                        Toast.show("Text copied")
                    }
                }
            }
        } else {
            editor.open(image: result.image, scale: result.scale)
        }
    }

    private func showPermissionAlert() {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Snag needs Screen Recording permission"
        alert.informativeText = "Turn on Snag under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Snag."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Snag")

        let menu = NSMenu()
        menu.delegate = self
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Open Editor", #selector(openEditor)))
        menu.addItem(item("New Empty Session", #selector(newSession)))
        menu.addItem(item("New from Clipboard", #selector(newFromClipboard)))
        menu.addItem(item("Show Captures in Finder", #selector(openFolder)))
        menu.addItem(.separator())
        loginItem = item("Launch at Login", #selector(toggleLaunchAtLogin))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addCaptureItems(to menu: NSMenu) {
        let mods: NSEvent.ModifierFlags = [.control, .shift]
        menu.addItem(item("Capture Region, Window or Full Screen", #selector(captureRegion), key: "c", mods))
        menu.addItem(item("Capture Full Screen", #selector(captureFullScreen), key: "f", mods))
        menu.addItem(item("Grab Text from Screen", #selector(captureText), key: "t", mods))
        menu.addItem(item("Capture Region in 5 Seconds", #selector(captureDelayed)))
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Shown while the editor is frontmost; gives text fields and the canvas their ⌘ shortcuts.
    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide Snag", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Snag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu("Snag", appMenu))

        let file = NSMenu(title: "File")
        let new = NSMenuItem(title: "New Empty Session", action: #selector(EditorController.newSession(_:)), keyEquivalent: "n")
        new.target = editor
        file.addItem(new)
        let save = NSMenuItem(title: "Save As…", action: #selector(EditorController.saveAs(_:)), keyEquivalent: "s")
        save.target = editor
        file.addItem(save)
        file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu("File", file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu("Edit", edit))

        let view = NSMenu(title: "View")
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        main.addItem(submenu("View", view))

        let capture = NSMenu(title: "Capture")
        addCaptureItems(to: capture)
        main.addItem(submenu("Capture", capture))

        NSApp.mainMenu = main
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func captureRegion() { capture(.region) }
    @objc private func captureFullScreen() { capture(.fullScreen) }
    @objc private func captureText() { capture(.text) }

    @objc private func captureDelayed() {
        Toast.show("Capturing in 5 seconds…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.capture(.region) }
    }

    @objc private func openEditor() { editor.showWindow() }
    @objc private func newSession() { editor.newSession() }

    @objc private func newFromClipboard() {
        editor.newSession()
        editor.paste()
    }
    @objc private func openFolder() { NSWorkspace.shared.open(Library.folder) }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Toast.show("Couldn’t change Launch at Login")
        }
    }
}
