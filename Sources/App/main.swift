import AppKit

// Hidden developer aids: `--render-test out.png` renders every annotation type to a file,
// `--ui-test out.png` snapshots the editor window after a scripted round of edits, and
// `--demo-shot out.png` makes the README's screenshot.
if let i = CommandLine.arguments.firstIndex(of: "--render-test"), CommandLine.arguments.count > i + 1 {
    RenderTest.run(output: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--ui-test"), CommandLine.arguments.count > i + 1 {
    RenderTest.ui(output: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--demo-shot"), CommandLine.arguments.count > i + 1 {
    DemoShot.run(output: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
