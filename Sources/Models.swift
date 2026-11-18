import Foundation

// MARK: - Local tracking

enum ItemStatus: String, Codable {
    case pending
    case ok
    case failed
    case missing
}

/// An item the user asked Backuper to keep in sync.
struct TrackedItem: Codable, Identifiable, Equatable {
    var id: UUID
    var sourcePath: String
    var relativePath: String
    var isDirectory: Bool
    var addedAt: Date
    var lastSyncAt: Date?
    var lastStatus: ItemStatus
    var lastMessage: String?
    var lastFileCount: Int
    var lastByteCount: Int64

    init(sourcePath: String,
         relativePath: String,
         isDirectory: Bool,
         id: UUID = UUID(),
         addedAt: Date = Date(),
         lastSyncAt: Date? = nil,
         lastStatus: ItemStatus = .pending,
         lastMessage: String? = nil,
         lastFileCount: Int = 0,
         lastByteCount: Int64 = 0) {
        self.id = id
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.addedAt = addedAt
        self.lastSyncAt = lastSyncAt
        self.lastStatus = lastStatus
        self.lastMessage = lastMessage
        self.lastFileCount = lastFileCount
        self.lastByteCount = lastByteCount
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var displayName: String { sourceURL.lastPathComponent }
    var destinationName: String { URL(fileURLWithPath: relativePath).lastPathComponent }
}

// MARK: - Metadata stored inside the cloud folder

/// A record of one backed-up item. This is what makes restoring possible on a
/// different Mac (or after reinstalling the app).
struct BackupRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var relativePath: String
    var originalPath: String
    /// Path relative to the user's home folder, e.g. "Desktop/Project Alpha".
    /// Lets a different user name on another Mac still resolve to ~/Desktop/...
    var originalPathFromHome: String?
    var isDirectory: Bool
    var addedAt: Date
    var lastSyncAt: Date?
    var hostName: String
    var userName: String
    var fileCount: Int
    var byteCount: Int64

    var displayName: String { URL(fileURLWithPath: relativePath).lastPathComponent }

    /// Where this record should be restored on *this* Mac.
    func resolvedOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let rel = originalPathFromHome, !rel.isEmpty {
            return home.appendingPathComponent(rel)
        }
        return URL(fileURLWithPath: originalPath)
    }
}

struct DestinationManifest: Codable {
    var schema: Int
    var app: String
    var updatedAt: Date
    var records: [BackupRecord]

    init(schema: Int = 1,
         app: String = "Backuper",
         updatedAt: Date = Date(),
         records: [BackupRecord] = []) {
        self.schema = schema
        self.app = app
        self.updatedAt = updatedAt
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case schema, app, updatedAt, records
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "Backuper"
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        records = try c.decodeIfPresent([BackupRecord].self, forKey: .records) ?? []
    }
}

// MARK: - Local configuration

struct AppConfiguration: Codable {
    var destinationPath: String
    var dailyEnabled: Bool
    var dailyHour: Int
    var dailyMinute: Int
    var items: [TrackedItem]
    var lastSyncAt: Date?

    init(destinationPath: String = "",
         dailyEnabled: Bool = true,
         dailyHour: Int = 9,
         dailyMinute: Int = 0,
         items: [TrackedItem] = [],
         lastSyncAt: Date? = nil) {
        self.destinationPath = destinationPath
        self.dailyEnabled = dailyEnabled
        self.dailyHour = dailyHour
        self.dailyMinute = dailyMinute
        self.items = items
        self.lastSyncAt = lastSyncAt
    }

    private enum CodingKeys: String, CodingKey {
        case destinationPath, dailyEnabled, dailyHour, dailyMinute, items, lastSyncAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath) ?? ""
        dailyEnabled = try c.decodeIfPresent(Bool.self, forKey: .dailyEnabled) ?? true
        dailyHour = try c.decodeIfPresent(Int.self, forKey: .dailyHour) ?? 9
        dailyMinute = try c.decodeIfPresent(Int.self, forKey: .dailyMinute) ?? 0
        items = try c.decodeIfPresent([TrackedItem].self, forKey: .items) ?? []
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }
}

// MARK: - Restore

enum RestorePolicy: String, Codable, CaseIterable, Identifiable {
    case keepBoth
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .replace: return "Replace"
        }
    }
}

struct RestoreItemResult {
    let record: BackupRecord
    var restoredPath: String?
    var filesCopied: Int = 0
    var bytesCopied: Int64 = 0
    var error: String?

    var succeeded: Bool { error == nil && restoredPath != nil }
}
