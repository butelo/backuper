import Darwin
import Foundation

/// Extended attributes written on backed-up files. They are convenient locally
/// (xattr -l file) but the manifest inside the cloud folder is the reliable
/// source of truth, because cloud sync services may not preserve xattrs.
enum Xattr {
    static let originalPath = "com.backuper.original-path"
    static let originalRelativePath = "com.backuper.original-relative-path"
    static let backedUpAt = "com.backuper.backed-up-at"
    static let itemID = "com.backuper.item-id"

    static func set(_ name: String, value: String, at url: URL) {
        let data = Data(value.utf8)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = setxattr(url.path, name, base, data.count, 0, 0)
        }
    }

    static func string(_ name: String, at url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return getxattr(url.path, name, base, size, 0, 0)
        }
        guard result > 0 else { return nil }
        return String(data: data.prefix(result), encoding: .utf8)
    }
}
