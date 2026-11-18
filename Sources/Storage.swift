import Foundation

enum Storage {
    /// Overridable for tests and demos:
    /// BACKUPER_SUPPORT_DIR=/tmp/foo ./Backuper.app/Contents/MacOS/Backuper
    static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["BACKUPER_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Backuper", isDirectory: true)
    }

    static var configURL: URL { supportDir.appendingPathComponent("config.json") }
    static var logURL: URL { supportDir.appendingPathComponent("backuper.log") }

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    static func loadConfig() -> AppConfiguration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else { return AppConfiguration() }
        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            Log.write("config load failed: \(error.localizedDescription)")
            // Keep the broken file around for troubleshooting instead of silently deleting it.
            let backup = supportDir.appendingPathComponent("config.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: configURL, to: backup)
            return AppConfiguration()
        }
    }

    static func saveConfig(_ config: AppConfiguration) {
        ensureSupportDir()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: [.atomic])
        } catch {
            Log.write("config save failed: \(error.localizedDescription)")
        }
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "com.backuper.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        queue.async {
            Storage.ensureSupportDir()
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: Storage.logURL.path)[.size] as? NSNumber,
               size.intValue > 1_000_000 {
                try? fm.removeItem(at: Storage.logURL)
            }
            if let handle = try? FileHandle(forWritingTo: Storage.logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: Storage.logURL)
            }
        }
    }
}
