import AppKit
import SwiftUI

enum PreviewRenderer {
    static func renderPopover(to path: String) {
        let state = AppState(preview: true)
        render(PopoverView(state: state, viewState: PopoverViewState()),
               size: NSSize(width: 400, height: 580), to: path)
    }

    static func renderRestore(to path: String) {
        let state = AppState(preview: true)
        render(RestoreView(state: state, viewState: RestoreViewState()),
               size: NSSize(width: 640, height: 520), to: path)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to path: String) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.setIsVisible(true)
        window.orderBack(nil)

        // Let SwiftUI lay out before caching the display.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("preview: couldn't create bitmap\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("preview: couldn't encode png\n".utf8))
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("preview: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        window.orderOut(nil)
        print("wrote \(path)")
    }
}
