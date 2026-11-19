import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState()
    private let popoverViewState = PopoverViewState()
    private var restoreWindowController: RestoreWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()

        state.reopenPopover = { [weak self] in self?.showPopover() }
        state.openRestoreWindow = { [weak self] in self?.showRestoreWindow() }

        state.$isSyncing
            .combineLatest(state.$isCreatingZip)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] syncing, zipping in self?.updateStatusIcon(busy: syncing || zipping) }
            .store(in: &cancellables)

        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showPopover()
            }
        } else if ProcessInfo.processInfo.environment["BACKUPER_SHOW_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.flushZipPasswords()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = symbolImage("icloud.and.arrow.up")
        button.imagePosition = .imageOnly
        button.toolTip = "Backuper — click to back up to the cloud"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func symbolImage(_ name: String, description: String = "Backuper") -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func updateStatusIcon(busy: Bool) {
        let image = busy
            ? symbolImage("arrow.triangle.2.circlepath", description: "Backuper is working")
            : symbolImage("icloud.and.arrow.up")
        statusItem.button?.image = image
        statusItem.button?.toolTip = busy ? "Backuper is working…" : "Backuper — click to back up to the cloud"
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let restore = NSMenuItem(title: "Restore from Backup…", action: #selector(menuRestore), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        menu.addItem(.separator())

        let sync = NSMenuItem(title: "Sync Now", action: #selector(menuSync), keyEquivalent: "s")
        sync.target = self
        menu.addItem(sync)

        let open = NSMenuItem(title: "Open Cloud Folder", action: #selector(menuOpenFolder), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Backuper", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRestore() { showRestoreWindow() }
    @objc private func menuSync() { state.syncAll() }
    @objc private func menuOpenFolder() { state.openDestination() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 580)
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state, viewState: popoverViewState))
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        state.refresh()
        if popover.isShown { popover.performClose(nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Restore window

    func showRestoreWindow() {
        if restoreWindowController == nil {
            restoreWindowController = RestoreWindowController(state: state)
        }
        popover.performClose(nil)
        state.reloadArchive()
        restoreWindowController?.showWindow(nil)
        restoreWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class RestoreWindowController: NSWindowController {
    private let viewState: RestoreViewState

    init(state: AppState) {
        let viewState = RestoreViewState()
        self.viewState = viewState
        let hosting = NSHostingController(rootView: RestoreView(state: state, viewState: viewState))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Restore from Backup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 520))
        window.minSize = NSSize(width: 580, height: 420)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
