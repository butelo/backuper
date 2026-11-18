import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--render-preview"), index + 1 < arguments.count {
    PreviewRenderer.renderPopover(to: arguments[index + 1])
    exit(0)
}
if let index = arguments.firstIndex(of: "--render-restore-preview"), index + 1 < arguments.count {
    PreviewRenderer.renderRestore(to: arguments[index + 1])
    exit(0)
}

let delegate = AppDelegate()
application.delegate = delegate
application.run()
