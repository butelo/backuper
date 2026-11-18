import Foundation

enum RestoreEngine {
    static func restore(records: [BackupRecord],
                        destinationRoot: URL,
                        policy: RestorePolicy,
                        progress: @escaping (String) -> Void = { _ in }) -> [RestoreItemResult] {
        records.map { restore(record: $0, destinationRoot: destinationRoot, policy: policy, progress: progress) }
    }

    static func restore(record: BackupRecord,
                        destinationRoot: URL,
                        policy: RestorePolicy,
                        progress: @escaping (String) -> Void = { _ in }) -> RestoreItemResult {
        var result = RestoreItemResult(record: record)
        let fm = FileManager.default
        let source = destinationRoot.appendingPathComponent(record.relativePath)

        guard fm.fileExists(atPath: source.path) else {
            result.error = "Backup copy not found (\(record.relativePath))"
            return result
        }

        var target = record.resolvedOriginalURL()
        let rootPath = destinationRoot.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
            result.error = "Original location is inside the backup folder"
            return result
        }
        if source.standardizedFileURL.path.hasPrefix(targetPath + "/") {
            result.error = "Restoring there would copy the backup into itself"
            return result
        }

        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path), policy == .keepBoth {
                target = uniqueRestoredURL(for: target)
            }
            progress("Restoring \(record.displayName)…")
            if policy == .replace, fm.fileExists(atPath: target.path) {
                try replaceCopy(from: source, to: target)
            } else {
                try fm.copyItem(at: source, to: target)
            }
            result.restoredPath = target.path
            let measured = measure(target)
            result.filesCopied = measured.files
            result.bytesCopied = measured.bytes
            Xattr.set("com.backuper.restored-at", value: ISO8601DateFormatter().string(from: Date()), at: target)
            Log.write("restored \(record.relativePath) -> \(target.path)")
        } catch {
            result.error = error.localizedDescription
            Log.write("restore failed: \(record.relativePath): \(error.localizedDescription)")
        }
        return result
    }

    /// Replace safely: move the old item aside, copy the new one, and only
    /// delete the old copy after the new one is fully in place.
    private static func replaceCopy(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).backuper-old-\(UUID().uuidString.prefix(8)).tmp")
        try fm.moveItem(at: target, to: temp)
        do {
            try fm.copyItem(at: source, to: target)
            try? fm.removeItem(at: temp)
        } catch {
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: temp, to: target)
            throw error
        }
    }

    static func uniqueRestoredURL(for url: URL) -> URL {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : (url.lastPathComponent as NSString).deletingPathExtension
        var counter = 1
        while true {
            let base = counter == 1 ? "\(stem) (restored)" : "\(stem) (restored \(counter))"
            let candidate = ext.isEmpty ? base : "\(base).\(ext)"
            let target = directory.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: target.path) { return target }
            counter += 1
        }
    }

    static func measure(_ url: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (1, Int64(size))
        }
        var files = 0
        var bytes: Int64 = 0
        if let enumerator = fm.enumerator(at: url,
                                          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                          options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return (files, bytes)
    }
}
