import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

struct Notice: Identifiable, Equatable {
    enum Kind: Equatable { case info, success, error }

    let id = UUID()
    let text: String
    let kind: Kind

    static func info(_ text: String) -> Notice { Notice(text: text, kind: .info) }
    static func success(_ text: String) -> Notice { Notice(text: text, kind: .success) }
    static func error(_ text: String) -> Notice { Notice(text: text, kind: .error) }
}

final class AppState: ObservableObject {
    // MARK: - Published state

    @Published private(set) var items: [TrackedItem] = []
    @Published private(set) var archive: [BackupRecord] = []
    @Published private(set) var destinationPath: String = ""
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var activity: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var notice: Notice?
    @Published private(set) var archiveError: String?
    @Published var launchAtLogin: Bool = false
    @Published var dailyEnabled: Bool = true
    @Published var dailyHour: Int = 9
    @Published var dailyMinute: Int = 0

    // MARK: - Password-protected ZIPs

    @Published private(set) var commonZipPassword: String = ""
    @Published private(set) var specificZipPassword: String = ""
    @Published private(set) var useCommonPassword: Bool = true
    @Published private(set) var zipPasswordError: String?
    @Published private(set) var isCreatingZip: Bool = false
    @Published private(set) var lastProtectedZipURL: URL?

    // MARK: - Wiring

    /// Set by AppDelegate to reopen the popover after a modal panel closes.
    var reopenPopover: (() -> Void)?
    /// Set by AppDelegate to show the restore window.
    var openRestoreWindow: (() -> Void)?

    private let isPreview: Bool
    private var pendingIDs = Set<UUID>()
    private var pendingDropURLs: [URL] = []
    private var pendingProtectedDropURLs: [URL] = []
    private let syncQueue = DispatchQueue(label: "com.backuper.sync", qos: .utility)
    private var timer: Timer?
    private var noticeWork: DispatchWorkItem?
    private var passwordSaveWork: [ZipPasswordAccount: DispatchWorkItem] = [:]

    // MARK: - Init

    init(preview: Bool = false) {
        isPreview = preview

        if preview {
            destinationPath = NSHomeDirectory() + "/Dropbox/Backuper"
            let now = Date()
            items = [
                TrackedItem(sourcePath: NSHomeDirectory() + "/Desktop/Design Assets",
                            relativePath: "Design Assets",
                            isDirectory: true,
                            lastSyncAt: now.addingTimeInterval(-5_400),
                            lastStatus: .ok,
                            lastFileCount: 128,
                            lastByteCount: 1_240_000_000),
                TrackedItem(sourcePath: NSHomeDirectory() + "/Downloads/Q3 Report.pdf",
                            relativePath: "Q3 Report.pdf",
                            isDirectory: false,
                            lastSyncAt: now.addingTimeInterval(-5_400),
                            lastStatus: .ok,
                            lastFileCount: 1,
                            lastByteCount: 2_400_000),
                TrackedItem(sourcePath: NSHomeDirectory() + "/Documents/Website",
                            relativePath: "Website",
                            isDirectory: true,
                            lastSyncAt: now.addingTimeInterval(-86_400),
                            lastStatus: .failed,
                            lastMessage: "3 files couldn’t be copied",
                            lastFileCount: 42,
                            lastByteCount: 86_000_000),
                TrackedItem(sourcePath: NSHomeDirectory() + "/Pictures/old-photos",
                            relativePath: "old-photos",
                            isDirectory: true,
                            lastStatus: .pending)
            ]
            lastSyncAt = now.addingTimeInterval(-5_400)
            archive = items.map { Catalog.record(for: $0) }
            launchAtLogin = false
            useCommonPassword = true
        } else {
            let config = Storage.loadConfig()
            destinationPath = config.destinationPath
            items = config.items
            dailyEnabled = config.dailyEnabled
            dailyHour = config.dailyHour
            dailyMinute = config.dailyMinute
            lastSyncAt = config.lastSyncAt
            useCommonPassword = config.useCommonPassword
            loadZipPasswords()

            if destinationPath.isEmpty, let existing = CloudFolderLocator.findExistingBackupDestination() {
                destinationPath = existing.path
                Log.write("found existing backup metadata at \(existing.path)")
            } else if destinationPath.isEmpty, let suggestion = CloudFolderLocator.suggestedDestination() {
                destinationPath = suggestion.path
            }
            if let override = ProcessInfo.processInfo.environment["BACKUPER_DESTINATION"], !override.isEmpty {
                destinationPath = override
            }

            launchAtLogin = SMAppService.mainApp.status == .enabled
            reloadArchive()
            // Materialise per-item metadata for archives created by older
            // versions (or by another Mac) so the redundant records exist too.
            if !items.isEmpty || !archive.isEmpty {
                writeArchive()
            }
            startScheduler()

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.syncIfDue()
            }
        }
    }

    // MARK: - Derived values

    var destinationURL: URL? {
        guard !destinationPath.isEmpty else { return nil }
        return URL(fileURLWithPath: destinationPath)
    }

    var destinationDisplayPath: String { Format.abbreviatedPath(destinationPath) }

    var destinationProviderName: String? {
        guard let url = destinationURL else { return nil }
        return CloudFolderLocator.providerName(for: url)
    }

    var destinationIsCloudFolder: Bool { destinationProviderName != nil }

    var canSync: Bool { !items.isEmpty && destinationURL != nil }

    var isBusy: Bool { isSyncing || isCreatingZip }

    var activeZipPassword: String {
        useCommonPassword ? commonZipPassword : specificZipPassword
    }

    var hasZipPassword: Bool { !activeZipPassword.isEmpty }

    var canCreateProtectedZip: Bool {
        destinationURL != nil && hasZipPassword && !isBusy
    }

    var itemCountText: String {
        "\(items.count) item\(items.count == 1 ? "" : "s") tracked"
    }

    var archiveCountText: String {
        "\(archive.count) item\(archive.count == 1 ? "" : "s") in the backup archive"
    }

    var trackedSize: Int64 {
        items.reduce(0) { $0 + $1.lastByteCount }
    }

    var lastSyncText: String {
        guard let lastSyncAt else { return "No backup run yet" }
        let calendar = Calendar.current
        if calendar.isDateInToday(lastSyncAt) {
            return "Last backup today at \(Format.time(lastSyncAt))"
        }
        if calendar.isDateInYesterday(lastSyncAt) {
            return "Last backup yesterday at \(Format.time(lastSyncAt))"
        }
        return "Last backup \(Format.dateTime(lastSyncAt))"
    }

    var dailyTime: Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = dailyHour
        components.minute = dailyMinute
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    func setDailyEnabled(_ enabled: Bool) {
        guard dailyEnabled != enabled else { return }
        dailyEnabled = enabled
        persist()
        Log.write("daily backup \(enabled ? "enabled" : "disabled")")
    }

    func setDailyTime(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        dailyHour = components.hour ?? 9
        dailyMinute = components.minute ?? 0
        persist()
        Log.write("daily sync set to \(dailyHour):\(dailyMinute)")
    }

    var nextSyncDate: Date? {
        guard dailyEnabled else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = dailyHour
        components.minute = dailyMinute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        if date <= Date() {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    var nextSyncText: String {
        guard dailyEnabled else { return "Daily backup is off" }
        guard let date = nextSyncDate else { return "" }
        let calendar = Calendar.current
        let time = Format.time(date)
        if calendar.isDateInToday(date) { return "Next backup today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "Next backup tomorrow at \(time)" }
        return "Next backup \(Format.weekday(date)) at \(time)"
    }

    func resolvedOriginalPath(for record: BackupRecord) -> String {
        record.resolvedOriginalURL().path
    }

    // MARK: - Protected ZIP passwords

    func setActiveZipPassword(_ value: String) {
        if useCommonPassword {
            commonZipPassword = value
        } else {
            specificZipPassword = value
        }
        zipPasswordError = nil
        schedulePasswordSave(for: useCommonPassword ? .common : .specific)
    }

    func setUseCommonPassword(_ enabled: Bool) {
        guard useCommonPassword != enabled else { return }
        useCommonPassword = enabled
        zipPasswordError = nil
        persist()
        Log.write("protected ZIP password mode: \(enabled ? "common" : "specific")")
    }

    func resetActiveZipPassword() {
        let account: ZipPasswordAccount = useCommonPassword ? .common : .specific
        if useCommonPassword {
            commonZipPassword = ""
        } else {
            specificZipPassword = ""
        }
        passwordSaveWork[account]?.cancel()
        passwordSaveWork[account] = nil
        savePassword(for: account)
        setNotice(.info("The \(useCommonPassword ? "common" : "specific") ZIP password was reset."), autoDismiss: 3)
    }

    func revealLastProtectedZip() {
        guard let url = lastProtectedZipURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadZipPasswords() {
        for account in ZipPasswordAccount.allCases {
            switch PasswordStore.load(account) {
            case .success(let password):
                setPasswordInMemory(password ?? "", for: account)
            case .failure(let error):
                zipPasswordError = "Couldn’t read the saved ZIP password: \(error.localizedDescription)"
                Log.write("keychain read failed (\(account.rawValue)): \(error.localizedDescription)")
            }
        }
    }

    private func setPasswordInMemory(_ value: String, for account: ZipPasswordAccount) {
        switch account {
        case .common: commonZipPassword = value
        case .specific: specificZipPassword = value
        }
    }

    private func password(for account: ZipPasswordAccount) -> String {
        switch account {
        case .common: return commonZipPassword
        case .specific: return specificZipPassword
        }
    }

    private func schedulePasswordSave(for account: ZipPasswordAccount) {
        passwordSaveWork[account]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.passwordSaveWork[account] = nil
            self.savePassword(for: account)
        }
        passwordSaveWork[account] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func savePassword(for account: ZipPasswordAccount) {
        guard !isPreview else { return }
        let value = password(for: account)
        let result: Result<Void, Error>
        if value.isEmpty {
            result = PasswordStore.delete(account)
        } else {
            result = PasswordStore.save(value, account: account)
        }
        switch result {
        case .success:
            zipPasswordError = nil
        case .failure(let error):
            zipPasswordError = "Couldn’t update the Keychain."
            Log.write("keychain save failed (\(account.rawValue)): \(error.localizedDescription)")
        }
    }

    /// Called on quit so a password typed in the last few hundred milliseconds
    /// is not lost to the debounce.
    func flushZipPasswords() {
        guard !isPreview else { return }
        for account in ZipPasswordAccount.allCases {
            passwordSaveWork[account]?.cancel()
            passwordSaveWork[account] = nil
            savePassword(for: account)
        }
    }

    // MARK: - Adding items

    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let root = destinationURL else {
            pendingDropURLs = urls
            setNotice(.info("Choose a folder inside OneDrive, Dropbox, Google Drive, iCloud Drive, or another synced folder."), autoDismiss: 6)
            chooseDestination()
            return
        }

        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var addedIDs: [UUID] = []
        var duplicateCount = 0
        var insideRootCount = 0
        var containsRootCount = 0
        var reservedCount = 0

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if let existing = items.first(where: { $0.sourcePath == url.path }) {
                duplicateCount += 1
                pendingIDs.insert(existing.id)
                continue
            }

            let sourcePath = url.path
            if sourcePath == rootPath || sourcePath.hasPrefix(rootPath + "/") {
                insideRootCount += 1
                continue
            }
            if isDir.boolValue && (rootPath == sourcePath || rootPath.hasPrefix(sourcePath + "/")) {
                containsRootCount += 1
                continue
            }
            if Catalog.isReservedName(url.lastPathComponent) {
                reservedCount += 1
                continue
            }

            // Re-adding an item that was previously tracked: keep using its
            // existing folder in the cloud backup instead of creating a "(2)" copy.
            let prior = archive.first(where: { $0.originalPath == sourcePath })
            let relativePath: String
            let itemID: UUID
            if let prior, fm.fileExists(atPath: root.appendingPathComponent(prior.relativePath).path) {
                relativePath = prior.relativePath
                itemID = prior.id
            } else {
                relativePath = uniqueRelativePath(for: url.lastPathComponent)
                itemID = UUID()
            }

            let item = TrackedItem(sourcePath: sourcePath,
                                   relativePath: relativePath,
                                   isDirectory: isDir.boolValue,
                                   id: itemID)
            items.append(item)
            addedIDs.append(item.id)
            pendingIDs.insert(item.id)
        }

        if !addedIDs.isEmpty {
            persist()
            Log.write("added \(addedIDs.count) item(s): \(addedIDs.map { $0.uuidString }.joined(separator: ","))")
            let text = addedIDs.count == 1
                ? "Added “\(items.first(where: { $0.id == addedIDs[0] })?.displayName ?? "item")” — copying to the cloud folder…"
                : "Added \(addedIDs.count) items — copying to the cloud folder…"
            setNotice(.success(text), autoDismiss: 4)
            runSync()
            reopenPopover?()
        } else if duplicateCount > 0 {
            persist()
            setNotice(.info("Already tracked — checking it again now."), autoDismiss: 4)
            runSync()
        } else if insideRootCount > 0 {
            setNotice(.error("That item is already inside the backup folder."))
        } else if containsRootCount > 0 {
            setNotice(.error("That folder contains the backup folder. Pick another folder."))
        } else if reservedCount > 0 {
            setNotice(.error("“\(Catalog.folderName)” is reserved for Backuper’s metadata."))
        } else {
            setNotice(.error("Nothing was added. Drop a file or folder from Finder."))
        }
    }

    private func uniqueRelativePath(for name: String) -> String {
        let fm = FileManager.default
        let root = destinationURL
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2

        func isTaken(_ value: String) -> Bool {
            if items.contains(where: { $0.relativePath.caseInsensitiveCompare(value) == .orderedSame }) {
                return true
            }
            if let root, fm.fileExists(atPath: root.appendingPathComponent(value).path) {
                return true
            }
            return false
        }

        while isTaken(candidate) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    func remove(_ item: TrackedItem) {
        items.removeAll { $0.id == item.id }
        pendingIDs.remove(item.id)
        persist()
        setNotice(.info("Stopped tracking “\(item.displayName)”. The copy in the cloud folder was left in place."), autoDismiss: 5)
    }

    // MARK: - Password-protected ZIP backups

    func createProtectedZip(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let root = destinationURL else {
            pendingProtectedDropURLs = urls
            setNotice(.info("Choose a folder inside OneDrive, Dropbox, Google Drive, iCloud Drive, or another synced folder."), autoDismiss: 6)
            chooseDestination()
            return
        }
        guard hasZipPassword else {
            setNotice(.error("Set a ZIP password first, below the drop areas."), autoDismiss: 7)
            return
        }
        guard !isBusy else {
            setNotice(.info("Wait for the current backup to finish, then drop again."), autoDismiss: 5)
            return
        }

        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var accepted: [URL] = []
        var seen = Set<String>()
        var insideRootCount = 0
        var containsRootCount = 0
        var reservedCount = 0
        var missingCount = 0

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                missingCount += 1
                continue
            }
            if url.path == rootPath || url.path.hasPrefix(rootPath + "/") {
                insideRootCount += 1
                continue
            }
            if isDir.boolValue && rootPath.hasPrefix(url.path + "/") {
                containsRootCount += 1
                continue
            }
            if Catalog.isReservedName(url.lastPathComponent) {
                reservedCount += 1
                continue
            }
            accepted.append(url)
        }

        guard !accepted.isEmpty else {
            if insideRootCount > 0 {
                setNotice(.error("That item is already inside the backup folder."))
            } else if containsRootCount > 0 {
                setNotice(.error("That folder contains the backup folder. Pick another folder."))
            } else if reservedCount > 0 {
                setNotice(.error("“\(Catalog.folderName)” is reserved for Backuper’s metadata."))
            } else if missingCount > 0 {
                setNotice(.error("Those items no longer exist."))
            } else {
                setNotice(.error("Nothing was added. Drop a file or folder from Finder."))
            }
            return
        }

        // Make sure the typed password is durable before it is used.
        savePassword(for: useCommonPassword ? .common : .specific)
        let password = activeZipPassword
        let account = useCommonPassword ? "common" : "specific"
        isCreatingZip = true
        activity = accepted.count == 1
            ? "Creating protected ZIP for “\(accepted[0].lastPathComponent)”…"
            : "Creating protected ZIP for \(accepted.count) items…"
        Log.write("zip start: \(accepted.count) source(s), \(account) password -> \(root.path)")

        syncQueue.async { [weak self] in
            guard let self else { return }
            do {
                let summary = try ZipEngine.createProtectedZip(sources: accepted,
                                                               destinationRoot: root,
                                                               password: password) { note in
                    DispatchQueue.main.async {
                        self.activity = note
                    }
                }
                DispatchQueue.main.async {
                    self.finishProtectedZip(summary)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishProtectedZip(error: error)
                }
            }
        }
    }

    private func finishProtectedZip(_ summary: ProtectedZipSummary) {
        isCreatingZip = false
        activity = nil
        lastProtectedZipURL = summary.archiveURL
        let name = summary.archiveURL.lastPathComponent

        if summary.errors.isEmpty {
            let contents: String
            if summary.fileCount == 0, summary.directoryCount > 0 {
                contents = "\(summary.directoryCount) folder\(summary.directoryCount == 1 ? "" : "s")"
            } else {
                let files = "\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s")"
                let size = summary.byteCount > 0 ? " · \(Format.bytes(summary.byteCount))" : ""
                contents = files + size
            }
            setNotice(.success("Protected ZIP “\(name)” saved with \(contents)"), autoDismiss: 6)
        } else {
            let extra = summary.errors[0]
            setNotice(.error("Protected ZIP saved with problems: \(summary.skippedCount) item\(summary.skippedCount == 1 ? "" : "s") skipped — \(extra)"), autoDismiss: 10)
        }
        Log.write("zip finish: \(name), files=\(summary.fileCount), bytes=\(summary.byteCount), skipped=\(summary.skippedCount)")
        reopenPopover?()
        if !pendingIDs.isEmpty {
            runSync()
        }
    }

    private func finishProtectedZip(error: Error) {
        isCreatingZip = false
        activity = nil
        setNotice(.error("Couldn’t create the protected ZIP: \(error.localizedDescription)"), autoDismiss: 10)
        Log.write("zip failed: \(error.localizedDescription)")
        reopenPopover?()
    }

    // MARK: - Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder inside OneDrive, Dropbox, Google Drive, iCloud Drive, or another synced folder."
        if let current = destinationURL {
            panel.directoryURL = current.deletingLastPathComponent()
        } else if let cloudRoot = CloudFolderLocator.candidateRoots().first {
            panel.directoryURL = cloudRoot
        }
        NSApp.activate(ignoringOtherApps: true)

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer { self.reopenPopover?() }
            if response == .OK, let url = panel.url {
                self.setDestination(url)
                if !self.pendingDropURLs.isEmpty {
                    let urls = self.pendingDropURLs
                    self.pendingDropURLs = []
                    self.add(urls: urls)
                }
                if !self.pendingProtectedDropURLs.isEmpty {
                    let urls = self.pendingProtectedDropURLs
                    self.pendingProtectedDropURLs = []
                    self.createProtectedZip(urls: urls)
                }
            } else {
                self.pendingDropURLs = []
                self.pendingProtectedDropURLs = []
            }
        }
        panel.begin(completionHandler: handler)
    }

    func setDestination(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != destinationPath else { return }
        destinationPath = path
        archive = []
        lastProtectedZipURL = nil
        persist()
        reloadArchive()
        Log.write("destination set to \(path)")

        if !CloudFolderLocator.isInsideCloudFolder(url) {
            setNotice(.error("That folder isn’t inside a known cloud-sync folder. Files will only be copied locally."), autoDismiss: 8)
        } else if !items.isEmpty {
            setNotice(.info("Backup folder changed — copying all items there now."), autoDismiss: 4)
        }

        if !items.isEmpty {
            pendingIDs.formUnion(items.map(\.id))
            runSync()
        }
    }

    func openDestination() {
        guard let root = destinationURL else {
            chooseDestination()
            return
        }
        if !FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                setNotice(.error("Couldn’t create the folder: \(error.localizedDescription)"))
                return
            }
        }
        NSWorkspace.shared.open(root)
    }

    func reveal(_ item: TrackedItem) {
        guard let root = destinationURL else { return }
        let url = root.appendingPathComponent(item.relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            setNotice(.error("“\(item.displayName)” hasn’t been copied yet."), autoDismiss: 5)
        }
    }

    func reveal(_ record: BackupRecord) {
        guard let root = destinationURL else { return }
        let url = root.appendingPathComponent(record.relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            setNotice(.error("That item is no longer in the backup folder."), autoDismiss: 5)
        }
    }

    // MARK: - Syncing

    func syncAll() {
        sync(ids: items.map(\.id))
    }

    func sync(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        guard destinationURL != nil else {
            chooseDestination()
            return
        }
        pendingIDs.formUnion(ids)
        runSync()
    }

    private func runSync() {
        guard !isPreview else { return }
        guard !isSyncing, !isCreatingZip else { return }
        guard let root = destinationURL else {
            chooseDestination()
            return
        }
        let batch = items.filter { pendingIDs.contains($0.id) }
        guard !batch.isEmpty else { return }
        pendingIDs.subtract(batch.map(\.id))

        isSyncing = true
        activity = batch.count == 1 ? "Backing up “\(batch[0].displayName)”…" : "Backing up \(batch.count) items…"
        Log.write("sync start: \(batch.count) item(s) -> \(root.path)")

        syncQueue.async { [weak self] in
            guard let self else { return }
            var results: [UUID: SyncResult] = [:]
            var rootError: String?
            var isDir: ObjCBool = false

            if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) {
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                } catch {
                    rootError = "Couldn’t create the backup folder: \(error.localizedDescription)"
                }
            }

            if rootError == nil {
                for (index, item) in batch.enumerated() {
                    DispatchQueue.main.async {
                        self.activity = batch.count > 1
                            ? "Backing up \(index + 1) of \(batch.count): \(item.displayName)"
                            : "Backing up “\(item.displayName)”"
                    }
                    let result = SyncEngine.sync(item: item, destinationRoot: root) { note in
                        DispatchQueue.main.async {
                            self.activity = "\(item.displayName) — \(note)"
                        }
                    }
                    results[item.id] = result
                }
            }

            DispatchQueue.main.async {
                self.finishSync(batch: batch, results: results, rootError: rootError)
            }
        }
    }

    private func finishSync(batch: [TrackedItem], results: [UUID: SyncResult], rootError: String?) {
        let now = Date()
        var copied = 0
        var skipped = 0
        var failedItems = 0
        var missingItems = 0
        var bytes: Int64 = 0
        var firstError: String?

        for item in batch {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            let result = results[item.id] ?? SyncResult(fatalError: rootError ?? "Unknown error")
            items[index].lastSyncAt = now

            if result.sourceMissing {
                items[index].lastStatus = .missing
                items[index].lastMessage = "Original file or folder no longer exists"
                missingItems += 1
                continue
            }
            if let fatal = result.fatalError {
                items[index].lastStatus = .failed
                items[index].lastMessage = fatal
                failedItems += 1
                firstError = firstError ?? fatal
                continue
            }
            if result.totalFiles > 0 {
                items[index].lastFileCount = result.totalFiles
                items[index].lastByteCount = result.totalBytes
            }
            if let summary = result.errorSummary {
                items[index].lastStatus = .failed
                items[index].lastMessage = summary
                failedItems += 1
                firstError = firstError ?? summary
            } else {
                items[index].lastStatus = .ok
                items[index].lastMessage = nil
            }
            copied += result.filesCopied
            skipped += result.filesSkipped
            bytes += result.bytesCopied
        }

        lastSyncAt = now
        isSyncing = false
        activity = nil
        persist()
        writeArchive()
        reloadArchive()

        var parts: [String] = []
        if copied > 0 { parts.append("\(copied) file\(copied == 1 ? "" : "s") copied") }
        if skipped > 0 && copied == 0 { parts.append("everything up to date") }
        if missingItems > 0 { parts.append("\(missingItems) source\(missingItems == 1 ? "" : "s") missing") }
        if failedItems > 0 { parts.append("\(failedItems) item\(failedItems == 1 ? "" : "s") failed") }
        if parts.isEmpty { parts.append("sync finished") }
        let summary = parts.joined(separator: " · ")

        if failedItems > 0 || missingItems > 0 {
            var text = "Backup finished with problems: \(summary)"
            if let firstError { text += " — \(firstError)" }
            setNotice(.error(text), autoDismiss: 10)
        } else if copied > 0 {
            let size = bytes > 0 ? " (\(Format.bytes(bytes)))" : ""
            setNotice(.success("Backed up \(copied) file\(copied == 1 ? "" : "s")\(size)"), autoDismiss: 4)
        } else if skipped > 0 {
            setNotice(.success("Everything is up to date."), autoDismiss: 3)
        }
        Log.write("sync finish: copied=\(copied) skipped=\(skipped) bytes=\(bytes) failed=\(failedItems) missing=\(missingItems)")

        if !pendingIDs.isEmpty {
            runSync()
        }
    }

    // MARK: - Archive / metadata

    func writeArchive() {
        guard !isPreview, let root = destinationURL else { return }
        do {
            let existing = try Catalog.load(from: root)
            let manifest = Catalog.merged(with: items, existing: existing)
            try Catalog.save(manifest, to: root)
            archive = manifest.records.sorted { ($0.lastSyncAt ?? $0.addedAt) > ($1.lastSyncAt ?? $1.addedAt) }
            archiveError = nil
        } catch {
            archiveError = error.localizedDescription
            Log.write("archive write failed: \(error.localizedDescription)")
        }
    }

    func reloadArchive() {
        guard let root = destinationURL else {
            archive = []
            archiveError = nil
            return
        }
        // Don't drop the last known archive just because the folder is
        // temporarily unavailable (it may also be a preview/test path).
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            let manifest = try Catalog.load(from: root)
            archive = (manifest?.records ?? []).sorted { ($0.lastSyncAt ?? $0.addedAt) > ($1.lastSyncAt ?? $1.addedAt) }
            archiveError = nil
        } catch {
            // Keep the last known list; the metadata may be temporarily
            // unavailable (offline, or a cloud-only placeholder still downloading).
            archiveError = error.localizedDescription
            Log.write("archive load failed: \(error.localizedDescription)")
        }
    }

    func showRestoreWindow() {
        openRestoreWindow?()
    }

    func restoreItem(_ item: TrackedItem) {
        guard let root = destinationURL else { return }
        let record = archive.first(where: { $0.id == item.id }) ?? Catalog.record(for: item)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restore “\(item.displayName)”?"
        alert.informativeText = """
        Backuper will copy the backup version in the cloud folder back to:
        \(Format.abbreviatedPath(item.sourcePath))

        Anything already at that location is kept; the restored copy gets a “(restored)” name.
        """
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        defer { reopenPopover?() }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = RestoreEngine.restore(record: record, destinationRoot: root, policy: .keepBoth)
        if let error = result.error {
            setNotice(.error("Restore failed: \(error)"), autoDismiss: 8)
        } else if let path = result.restoredPath {
            setNotice(.success("Restored to \(Format.abbreviatedPath(path))"), autoDismiss: 6)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    // MARK: - Scheduling

    private func startScheduler() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.syncIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                         selector: #selector(handleWake),
                                                         name: NSWorkspace.didWakeNotification,
                                                         object: nil)
    }

    @objc private func handleWake() {
        syncIfDue()
    }

    func syncIfDue() {
        guard !isPreview, dailyEnabled, !isSyncing, !items.isEmpty, destinationURL != nil else { return }
        let now = Date()
        guard let scheduled = mostRecentScheduledDate(before: now) else { return }
        if let lastSyncAt, lastSyncAt >= scheduled { return }
        Log.write("daily sync due (scheduled \(scheduled))")
        sync(ids: items.map(\.id))
    }

    private func mostRecentScheduledDate(before now: Date) -> Date? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = dailyHour
        components.minute = dailyMinute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today)
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin {
                if SMAppService.mainApp.status == .requiresApproval {
                    setNotice(.info("Allow Backuper in System Settings › General › Login Items."), autoDismiss: 10)
                    openLoginItemsSettings()
                } else {
                    setNotice(.error("Couldn’t enable launch at login. Move Backuper to /Applications and try again."), autoDismiss: 8)
                }
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            setNotice(.error("Launch at login failed: \(error.localizedDescription)"), autoDismiss: 8)
            Log.write("login item error: \(error.localizedDescription)")
        }
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notices

    private func setNotice(_ notice: Notice, autoDismiss: TimeInterval = 6) {
        self.notice = notice
        noticeWork?.cancel()
        guard autoDismiss > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            if self?.notice?.id == notice.id {
                self?.notice = nil
            }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismiss, execute: work)
    }

    // MARK: - Drag & drop

    func handleDrop(providers: [NSItemProvider], protected: Bool = false) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                defer { group.leave() }
                if let error {
                    Log.write("drop load failed: \(error.localizedDescription)")
                    return
                }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                }
                guard let url, url.isFileURL else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
            if protected {
                self.createProtectedZip(urls: unique)
            } else {
                self.add(urls: unique)
            }
        }
    }

    // MARK: - Persistence / refresh

    private func persist() {
        guard !isPreview else { return }
        let config = AppConfiguration(destinationPath: destinationPath,
                                      dailyEnabled: dailyEnabled,
                                      dailyHour: dailyHour,
                                      dailyMinute: dailyMinute,
                                      items: items,
                                      lastSyncAt: lastSyncAt,
                                      useCommonPassword: useCommonPassword)
        Storage.saveConfig(config)
    }

    func refresh() {
        guard !isPreview else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let root = destinationURL, FileManager.default.fileExists(atPath: root.path) {
            reloadArchive()
        }
    }
}
