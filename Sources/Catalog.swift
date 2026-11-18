import Foundation

/// Metadata that lives *inside* the cloud-synced folder, next to the backed-up
/// items. The cloud client uploads it like any other file, so a fresh Mac can
/// restore from the cloud without any local app state.
///
/// `_Backuper/manifest.json` is the index. `_Backuper/records/<uuid>.json`
/// mirrors each item so the index can be rebuilt if it is lost or corrupted,
/// and `_Backuper/RECOVERY.md` is a human-readable recovery list.
enum Catalog {
    static let folderName = "_Backuper"
    static let manifestName = "manifest.json"
    static let readmeName = "README.txt"
    static let recoveryName = "RECOVERY.md"
    static let recordsDirName = "records"

    static var hostName: String { ProcessInfo.processInfo.hostName }
    static var userName: String { NSUserName() }

    private static let isoFormatter = ISO8601DateFormatter()

    static func metadataDir(for destinationRoot: URL) -> URL {
        destinationRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    static func manifestURL(for destinationRoot: URL) -> URL {
        metadataDir(for: destinationRoot).appendingPathComponent(manifestName)
    }

    static func recordsDir(for destinationRoot: URL) -> URL {
        metadataDir(for: destinationRoot).appendingPathComponent(recordsDirName, isDirectory: true)
    }

    static func isReservedName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(folderName) == .orderedSame
    }

    static func pathFromHome(_ path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }

    // MARK: - Loading

    static func load(from destinationRoot: URL) throws -> DestinationManifest? {
        let url = manifestURL(for: destinationRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try decodeManifest(at: url)
            } catch {
                Log.write("manifest unreadable: \(error.localizedDescription); trying per-item records")
                if let recovered = recoveredManifest(from: destinationRoot) {
                    Log.write("rebuilt manifest from \(recovered.records.count) per-item record(s)")
                    try? save(recovered, to: destinationRoot)
                    return recovered
                }
                throw error
            }
        }

        if let recovered = recoveredManifest(from: destinationRoot) {
            Log.write("manifest missing; rebuilt from \(recovered.records.count) per-item record(s)")
            try? save(recovered, to: destinationRoot)
            return recovered
        }
        return nil
    }

    private static func decodeManifest(at url: URL) throws -> DestinationManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DestinationManifest.self, from: data)
    }

    /// Fallback when manifest.json is missing or damaged: every record is also
    /// stored as its own small JSON file next to the manifest.
    private static func recoveredManifest(from destinationRoot: URL) -> DestinationManifest? {
        let fm = FileManager.default
        let dir = recordsDir(for: destinationRoot)
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recordsByID: [UUID: BackupRecord] = [:]

        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: file)
                let record = try decoder.decode(BackupRecord.self, from: data)
                guard !record.relativePath.isEmpty, !record.originalPath.isEmpty else { continue }
                if let existing = recordsByID[record.id],
                   (existing.lastSyncAt ?? .distantPast) > (record.lastSyncAt ?? .distantPast) {
                    continue
                }
                recordsByID[record.id] = record
            } catch {
                Log.write("skipping unreadable record \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !recordsByID.isEmpty else { return nil }
        let records = recordsByID.values.sorted { $0.addedAt < $1.addedAt }
        return DestinationManifest(updatedAt: Date(), records: records)
    }

    // MARK: - Saving

    static func save(_ manifest: DestinationManifest, to destinationRoot: URL) throws {
        let fm = FileManager.default
        let dir = metadataDir(for: destinationRoot)
        let recordDir = recordsDir(for: destinationRoot)
        try fm.createDirectory(at: recordDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // Per-item copies first, so a crash never leaves the index ahead of
        // the individual records.
        for record in manifest.records {
            do {
                let data = try encoder.encode(record)
                let url = recordDir.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
                try data.write(to: url, options: [.atomic])
            } catch {
                Log.write("record write failed for \(record.relativePath): \(error.localizedDescription)")
            }
        }

        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(for: destinationRoot), options: [.atomic])

        try? recoveryText(manifest).data(using: .utf8)?
            .write(to: dir.appendingPathComponent(recoveryName), options: [.atomic])
        try? readmeText().data(using: .utf8)?
            .write(to: dir.appendingPathComponent(readmeName), options: [.atomic])
    }

    static func record(for item: TrackedItem) -> BackupRecord {
        BackupRecord(id: item.id,
                     relativePath: item.relativePath,
                     originalPath: item.sourcePath,
                     originalPathFromHome: pathFromHome(item.sourcePath),
                     isDirectory: item.isDirectory,
                     addedAt: item.addedAt,
                     lastSyncAt: item.lastSyncAt,
                     hostName: hostName,
                     userName: userName,
                     fileCount: item.lastFileCount,
                     byteCount: item.lastByteCount)
    }

    /// Merge records for tracked items into the existing manifest, preserving
    /// records that came from other Macs or items no longer tracked locally.
    static func merged(with items: [TrackedItem], existing: DestinationManifest?) -> DestinationManifest {
        var recordsByID: [UUID: BackupRecord] = [:]
        for record in existing?.records ?? [] {
            recordsByID[record.id] = record
        }
        for item in items {
            recordsByID[item.id] = record(for: item)
        }
        let sorted = recordsByID.values.sorted { $0.addedAt < $1.addedAt }
        return DestinationManifest(updatedAt: Date(), records: sorted)
    }

    // MARK: - Human-readable files

    private static func recoveryText(_ manifest: DestinationManifest) -> String {
        var lines: [String] = []
        lines.append("Backuper recovery index")
        lines.append("=======================")
        lines.append("")
        lines.append("Generated: \(isoFormatter.string(from: Date()))")
        lines.append("Items: \(manifest.records.count)")
        lines.append("")
        lines.append("This file lives inside your cloud-synced folder, so your cloud client uploads it")
        lines.append("together with the backups. manifest.json is the machine-readable index;")
        lines.append("records/<uuid>.json keeps one copy per item so the index can be rebuilt")
        lines.append("if it is ever lost or damaged.")
        lines.append("")
        lines.append("To restore with Backuper: open the app on any Mac, choose this same")
        lines.append("cloud folder, then use Restore from Backup.")
        lines.append("To restore by hand: copy the item from")
        lines.append("\"<this folder>/<relative path>\" back to \"<original path>\" below.")
        lines.append("")
        lines.append("Items")
        lines.append("-----")
        for (index, record) in manifest.records.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \"\(record.relativePath)\" (\(record.isDirectory ? "folder" : "file"))")
            lines.append("   original:   \(record.originalPath)")
            if let fromHome = record.originalPathFromHome {
                lines.append("   from home:  ~/\(fromHome)")
            }
            if let last = record.lastSyncAt {
                lines.append("   last sync:  \(isoFormatter.string(from: last)) on \(record.hostName) (\(record.userName))")
            }
            lines.append("   size:       \(record.fileCount) file(s), \(record.byteCount) bytes")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func readmeText() -> String {
        """
        Backuper metadata
        =================

        This folder is managed by Backuper. It stores everything needed to
        restore backed-up items to the place they originally came from. Your
        cloud-sync client uploads this folder together with the backups.

        manifest.json
          The index. For every item it stores:
            - relativePath          where the item lives inside this backup folder
            - originalPath          its full path on the Mac it came from
            - originalPathFromHome  same path relative to the home folder
            - addedAt / lastSyncAt / hostName / userName
            - fileCount / byteCount

        records/<uuid>.json
          One metadata file per item. Backuper rebuilds manifest.json from these
          if it is lost or damaged.

        RECOVERY.md
          A human-readable list of items and their original paths, for manual
          recovery without the app.

        Backups themselves live next to this folder, at the paths listed in
        relativePath. Nothing in this folder is uploaded anywhere except by your
        own cloud-sync client.

        To restore: open Backuper on any Mac, choose this folder as the cloud
        folder, and choose "Restore from Backup..." from the menu bar window.

        Do not edit manifest.json by hand; Backuper rewrites it on every sync.
        """
    }
}
