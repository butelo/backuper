import Foundation

/// A cloud-synced folder discovered on this Mac.
struct CloudFolder {
    let name: String
    let url: URL
}

/// Finds folders that are synced by a cloud client: OneDrive, Dropbox,
/// Google Drive, iCloud Drive, Box, pCloud, MEGA, Sync.com, Tresorit,
/// Nextcloud/ownCloud. Any other folder can still be chosen manually.
enum CloudFolderLocator {
    private static let providerPriority: [String: Int] = [
        "OneDrive": 0,
        "Dropbox": 1,
        "Google Drive": 2,
        "iCloud Drive": 3,
        "Box": 4,
        "pCloud": 5,
        "MEGA": 6,
        "Sync.com": 7,
        "Tresorit": 8,
        "Nextcloud": 9,
        "ownCloud": 10
    ]

    /// Maps a folder name such as "OneDrive-Personal" or "Dropbox (Personal)"
    /// to a provider name. Used both for detection and for the UI hint.
    static func providerName(forFolderName name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("onedrive") { return "OneDrive" }
        if lower.hasPrefix("dropbox") { return "Dropbox" }
        if lower.hasPrefix("googledrive") || lower.hasPrefix("google drive") { return "Google Drive" }
        if lower == "box" || lower.hasPrefix("box sync") || lower.hasPrefix("box-") { return "Box" }
        if lower.hasPrefix("pcloud") { return "pCloud" }
        if lower == "mega" || lower.hasPrefix("mega-") || lower.hasPrefix("mega ") { return "MEGA" }
        if lower == "sync" || lower.hasPrefix("sync.com") { return "Sync.com" }
        if lower.hasPrefix("tresorit") { return "Tresorit" }
        if lower.hasPrefix("nextcloud") { return "Nextcloud" }
        if lower.hasPrefix("owncloud") { return "ownCloud" }
        return nil
    }

    /// Returns the provider a path belongs to, or nil when it is not inside a
    /// recognisable cloud-sync location.
    static func providerName(for url: URL) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path

        let cloudStoragePrefix = home + "/Library/CloudStorage/"
        if path.hasPrefix(cloudStoragePrefix) {
            let rest = String(path.dropFirst(cloudStoragePrefix.count))
            guard let first = rest.split(separator: "/").first else { return nil }
            return providerName(forFolderName: String(first))
        }

        let iCloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == iCloudRoot || path.hasPrefix(iCloudRoot + "/") {
            return "iCloud Drive"
        }

        let homePrefix = home + "/"
        if path.hasPrefix(homePrefix) {
            let rest = String(path.dropFirst(homePrefix.count))
            guard let first = rest.split(separator: "/").first else { return nil }
            return providerName(forFolderName: String(first))
        }

        let sharedPrefix = "/Users/Shared/"
        if path.hasPrefix(sharedPrefix) {
            let rest = String(path.dropFirst(sharedPrefix.count))
            guard let first = rest.split(separator: "/").first else { return nil }
            return providerName(forFolderName: String(first))
        }

        return nil
    }

    static func isInsideCloudFolder(_ url: URL) -> Bool {
        providerName(for: url) != nil
    }

    /// Cloud folders that exist on this Mac, in a stable provider order.
    static func cloudFolders() -> [CloudFolder] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [CloudFolder] = []
        var seen = Set<String>()

        func add(_ provider: String?, _ url: URL) {
            guard let provider else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return
            }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            found.append(CloudFolder(name: provider, url: standardized))
        }

        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: cloudStorage,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            for entry in entries {
                add(providerName(forFolderName: entry.lastPathComponent), entry)
            }
        }

        if let entries = try? fm.contentsOfDirectory(at: home,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            for entry in entries {
                add(providerName(forFolderName: entry.lastPathComponent), entry)
            }
        }

        add("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                                        isDirectory: true))

        let shared = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: shared,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            for entry in entries {
                add(providerName(forFolderName: entry.lastPathComponent), entry)
            }
        }

        found.sort { lhs, rhs in
            let lhsPriority = providerPriority[lhs.name] ?? 99
            let rhsPriority = providerPriority[rhs.name] ?? 99
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        return found
    }

    static func candidateRoots() -> [URL] {
        cloudFolders().map(\.url)
    }

    /// Default landing spot: a "Backuper" folder inside the first cloud folder.
    static func suggestedDestination() -> URL? {
        guard let root = cloudFolders().first else { return nil }
        return root.url.appendingPathComponent("Backuper", isDirectory: true)
    }

    /// Looks for an existing Backuper metadata folder (for example
    /// ~/Library/CloudStorage/OneDrive-Personal/Backuper or ~/Dropbox/Backuper)
    /// so a fresh Mac can pick up an archive that is already in the cloud.
    static func findExistingBackupDestination(in roots: [URL]? = nil) -> URL? {
        let fm = FileManager.default
        let candidates = roots ?? candidateRoots()

        func hasMetadata(_ url: URL) -> Bool {
            let manifest = url
                .appendingPathComponent(Catalog.folderName, isDirectory: true)
                .appendingPathComponent(Catalog.manifestName)
            return fm.fileExists(atPath: manifest.path)
        }

        for root in candidates {
            if hasMetadata(root) { return root }

            guard let children = try? fm.contentsOfDirectory(at: root,
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else {
                continue
            }
            let directories = children.filter { child in
                guard !child.lastPathComponent.hasPrefix(".") else { return false }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true
            }

            // Prefer the conventional "Backuper" folder before scanning others.
            if let named = directories.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare("Backuper") == .orderedSame
            }), hasMetadata(named) {
                return named
            }
            for child in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where hasMetadata(child) {
                return child
            }
        }
        return nil
    }
}
