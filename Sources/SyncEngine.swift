import Foundation

struct SyncResult {
    var filesCopied = 0
    var filesSkipped = 0
    var bytesCopied: Int64 = 0
    var totalFiles = 0
    var totalBytes: Int64 = 0
    var sourceMissing = false
    var fatalError: String?
    var fileErrors: [String] = []

    init() {}

    init(fatalError: String) {
        self.fatalError = fatalError
    }

    var errorSummary: String? {
        if let fatalError { return fatalError }
        if fileErrors.isEmpty { return nil }
        if fileErrors.count == 1 { return fileErrors[0] }
        return "\(fileErrors.count) files couldn’t be copied"
    }
}

final class SyncContext {
    let destinationRoot: URL
    let item: TrackedItem
    let activity: (String) -> Void
    var filesCopied = 0
    var filesSkipped = 0
    var bytesCopied: Int64 = 0
    var totalFiles = 0
    var totalBytes: Int64 = 0
    var errors: [String] = []

    init(destinationRoot: URL, item: TrackedItem, activity: @escaping (String) -> Void) {
        self.destinationRoot = destinationRoot
        self.item = item
        self.activity = activity
    }

    func addError(_ message: String) {
        if errors.count < 8 { errors.append(message) }
        Log.write("sync error: \(message)")
    }
}

enum SyncEngine {
    static let fm = FileManager.default
    private static let isoFormatter = ISO8601DateFormatter()

    private static let excludedNames: Set<String> = [
        ".DS_Store", "desktop.ini", ".localized", ".TemporaryItems", ".Trashes"
    ]

    static func shouldExclude(_ name: String) -> Bool {
        if excludedNames.contains(name) { return true }
        if name.hasPrefix("~$") { return true }               // Office lock files
        if name.hasPrefix(".backuper-") { return true }       // our temp files
        if name == Catalog.folderName { return true }         // metadata folder
        return false
    }

    static func sync(item: TrackedItem,
                     destinationRoot: URL,
                     activity: @escaping (String) -> Void = { _ in }) -> SyncResult {
        var result = SyncResult()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: item.sourcePath, isDirectory: &isDir) else {
            result.sourceMissing = true
            return result
        }

        let destination = destinationRoot.appendingPathComponent(item.relativePath)
        let context = SyncContext(destinationRoot: destinationRoot, item: item, activity: activity)
        do {
            if isDir.boolValue {
                try ensureDirectory(destination)
                try copyDirectoryContents(from: item.sourceURL, to: destination, context: context)
            } else {
                try ensureDirectory(destination.deletingLastPathComponent())
                copyFile(from: item.sourceURL, to: destination, context: context)
            }
            applyItemMetadata(item: item, destination: destination)
        } catch {
            result.fatalError = error.localizedDescription
            Log.write("sync fatal: \(item.sourcePath): \(error.localizedDescription)")
        }

        result.filesCopied = context.filesCopied
        result.filesSkipped = context.filesSkipped
        result.bytesCopied = context.bytesCopied
        result.totalFiles = context.totalFiles
        result.totalBytes = context.totalBytes
        result.fileErrors = context.errors
        return result
    }

    // MARK: - Copying

    private static func copyDirectoryContents(from source: URL, to destination: URL, context: SyncContext) throws {
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: source,
                                                 includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                 options: [])
        } catch {
            context.addError("\(source.lastPathComponent): \(error.localizedDescription)")
            return
        }

        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = entry.lastPathComponent
            if shouldExclude(name) { continue }
            if entry.standardizedFileURL.path == context.destinationRoot.standardizedFileURL.path { continue }

            let target = destination.appendingPathComponent(name)
            do {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    try copySymbolicLink(from: entry, to: target)
                    context.filesCopied += 1
                    context.totalFiles += 1
                    setFileMetadata(source: entry, destination: target, context: context)
                } else if values.isDirectory == true {
                    try ensureDirectory(target)
                    try copyDirectoryContents(from: entry, to: target, context: context)
                } else {
                    copyFile(from: entry, to: target, context: context)
                }
            } catch {
                context.addError("\(name): \(error.localizedDescription)")
            }
        }
    }

    private static func copyFile(from source: URL, to destination: URL, context: SyncContext) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        context.totalFiles += 1
        context.totalBytes += Int64(size)

        guard needsCopy(source: source, destination: destination) else {
            context.filesSkipped += 1
            if Xattr.string(Xattr.originalPath, at: destination) == nil {
                setFileMetadata(source: source, destination: destination, context: context)
            }
            return
        }
        context.activity("Copying \(source.lastPathComponent)")
        do {
            try copyReplacing(source, destination)
            context.filesCopied += 1
            context.bytesCopied += Int64(size)
            setFileMetadata(source: source, destination: destination, context: context)
        } catch {
            context.addError("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Copy through a temporary file so a failed copy never leaves a truncated
    /// backup behind.
    private static func copyReplacing(_ source: URL, _ destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".backuper-\(UUID().uuidString).tmp")
        try fm.copyItem(at: source, to: temp)

        // Move the old copy aside rather than deleting it, so a failure while
        // installing the new file cannot lose the previous backup.
        var oldCopy: URL?
        if fm.fileExists(atPath: destination.path) {
            let old = directory.appendingPathComponent(".backuper-old-\(UUID().uuidString).tmp")
            try fm.moveItem(at: destination, to: old)
            oldCopy = old
        }

        do {
            try fm.moveItem(at: temp, to: destination)
            if let oldCopy { try? fm.removeItem(at: oldCopy) }
            // Keep the source timestamp so the next daily check can skip it.
            if let modified = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
            }
        } catch {
            if let oldCopy {
                try? fm.moveItem(at: oldCopy, to: destination)
            }
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static func copySymbolicLink(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path)
            || (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fm.removeItem(at: destination)
        }
        let target = try fm.destinationOfSymbolicLink(atPath: source.path)
        try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// True when the destination is missing, is a different type, has a
    /// different size, or the source is newer. A newer destination (for
    /// example a file edited in the cloud) is never clobbered.
    private static func needsCopy(source: URL, destination: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir) else { return true }
        if isDir.boolValue { return true }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let sourceValues = try? source.resourceValues(forKeys: keys),
              let destinationValues = try? destination.resourceValues(forKeys: keys) else {
            return true
        }
        if sourceValues.isRegularFile == true, destinationValues.isRegularFile != true { return true }

        let sourceDate = sourceValues.contentModificationDate
        let destinationDate = destinationValues.contentModificationDate

        // A copy in the cloud folder that is newer than the original is left alone, so
        // edits made in the cloud are never silently clobbered.
        if let sourceDate, let destinationDate, destinationDate.timeIntervalSince(sourceDate) > 1 {
            return false
        }
        if let sourceSize = sourceValues.fileSize, let destinationSize = destinationValues.fileSize,
           sourceSize != destinationSize {
            return true
        }
        if let sourceDate, let destinationDate, sourceDate.timeIntervalSince(destinationDate) > 1 {
            return true
        }
        return false
    }

    // MARK: - Metadata

    private static func setFileMetadata(source: URL, destination: URL, context: SyncContext) {
        let now = isoFormatter.string(from: Date())
        Xattr.set(Xattr.originalPath, value: source.path, at: destination)
        Xattr.set(Xattr.itemID, value: context.item.id.uuidString, at: destination)
        Xattr.set(Xattr.backedUpAt, value: now, at: destination)
    }

    private static func applyItemMetadata(item: TrackedItem, destination: URL) {
        guard fm.fileExists(atPath: destination.path) else { return }
        let now = isoFormatter.string(from: Date())
        Xattr.set(Xattr.originalPath, value: item.sourcePath, at: destination)
        Xattr.set(Xattr.originalRelativePath, value: Catalog.pathFromHome(item.sourcePath) ?? item.sourcePath, at: destination)
        Xattr.set(Xattr.backedUpAt, value: now, at: destination)
        Xattr.set(Xattr.itemID, value: item.id.uuidString, at: destination)
    }
}
