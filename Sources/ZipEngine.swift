import Compression
import Foundation

// MARK: - Public types

enum ZipEngineError: LocalizedError {
    case emptyPassword
    case noSources
    case noEntries(String)
    case sourceChanged(String)
    case archiveCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Enter a password before creating a protected ZIP."
        case .noSources:
            return "Nothing was dropped."
        case .noEntries(let detail):
            if detail.isEmpty {
                return "No files could be added to the protected ZIP."
            }
            return "No files could be added to the protected ZIP — \(detail)"
        case .sourceChanged(let name):
            return "“\(name)” changed while it was being archived. Try again."
        case .archiveCreationFailed:
            return "Couldn’t create the protected ZIP file."
        }
    }
}

struct ProtectedZipSummary {
    var archiveURL: URL
    var fileCount = 0
    var directoryCount = 0
    var byteCount: Int64 = 0
    var skippedCount = 0
    var errors: [String] = []
}

struct ZipEngineOptions {
    /// Files at or below this size are compressed in memory. Larger files are
    /// stored without compression so memory use stays bounded.
    var compressionLimit = 64 * 1024 * 1024
    var compressSmallFiles = true
    /// Used by the tests to exercise the ZIP64 local-header path with a small
    /// archive.
    var forceZip64 = false
}

/// Creates password-protected ZIP archives without shelling out to `zip -P`
/// (which would expose the password in the process argument list).
///
/// The format is the traditional PKWARE ZIP 2.0 encryption (ZipCrypto), the only
/// password scheme macOS's built-in Archive Utility and `unzip` understand. It
/// is compatible everywhere, but it is not modern cryptography: use a long,
/// unique passphrase. The AES ZIP variants are not readable by macOS's tools.
enum ZipEngine {
    static let folderName = "Protected Zips"

    static func protectedZipsDirectory(for destinationRoot: URL) -> URL {
        destinationRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Creates `<cloud folder>/Protected Zips/<name>.zip` and returns its path.
    static func createProtectedZip(sources: [URL],
                                   destinationRoot: URL,
                                   password: String,
                                   now: Date = Date(),
                                   options: ZipEngineOptions = ZipEngineOptions(),
                                   progress: (String) -> Void = { _ in }) throws -> ProtectedZipSummary {
        guard !password.isEmpty else { throw ZipEngineError.emptyPassword }
        let directory = protectedZipsDirectory(for: destinationRoot)
        let archiveURL = uniqueArchiveURL(in: directory, sources: sources, now: now)
        return try createArchive(at: archiveURL,
                                 sources: sources,
                                 password: password,
                                 options: options,
                                 progress: progress)
    }

    /// Lower-level entry point used by the tests.
    static func createArchive(at archiveURL: URL,
                              sources: [URL],
                              password: String,
                              options: ZipEngineOptions = ZipEngineOptions(),
                              progress: (String) -> Void = { _ in }) throws -> ProtectedZipSummary {
        guard !password.isEmpty else { throw ZipEngineError.emptyPassword }
        guard !sources.isEmpty else { throw ZipEngineError.noSources }

        let fm = FileManager.default
        let directory = archiveURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStaleTemporaryArchives(in: directory)

        let tempURL = directory
            .appendingPathComponent(".backuper-\(UUID().uuidString).zip.tmp")
        guard fm.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw ZipEngineError.archiveCreationFailed
        }

        let handle = try FileHandle(forWritingTo: tempURL)
        var handleClosed = false
        func cleanUp() {
            if !handleClosed {
                try? handle.close()
                handleClosed = true
            }
            try? fm.removeItem(at: tempURL)
        }

        do {
            let writer = ZipFileWriter(handle: handle, password: password)
            var summary = ProtectedZipSummary(archiveURL: archiveURL)
            var dirStack = Set<String>()
            var topLevelNames = Set<String>()

            for source in sources {
                let name = source.lastPathComponent.isEmpty ? "Item" : source.lastPathComponent
                let uniqueName = uniqueTopLevelName(name, used: &topLevelNames)
                try addTree(url: source,
                            archivePath: uniqueName,
                            writer: writer,
                            summary: &summary,
                            options: options,
                            progress: progress,
                            dirStack: &dirStack)
            }

            guard writer.entryCount > 0 else {
                throw ZipEngineError.noEntries(summary.errors.first ?? "")
            }

            try writer.finish()
            try handle.close()
            handleClosed = true
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: tempURL.path)
            if fm.fileExists(atPath: archiveURL.path) {
                try fm.removeItem(at: archiveURL)
            }
            try fm.moveItem(at: tempURL, to: archiveURL)

            if summary.errors.isEmpty == false {
                Log.write("zip finished with \(summary.errors.count) skipped item(s): \(summary.errors.joined(separator: "; "))")
            }
            return summary
        } catch {
            cleanUp()
            throw error
        }
    }

    private static func removeStaleTemporaryArchives(in directory: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(".backuper-"), name.hasSuffix(".zip.tmp") else { continue }
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }

    static func archiveBaseName(for sources: [URL], now: Date = Date()) -> String {
        if sources.count == 1, let source = sources.first {
            let name = source.lastPathComponent
            if !name.isEmpty {
                // Keep the whole name (including extensions such as ".pdf") and
                // only append ".zip", so "report.pdf" becomes "report.pdf.zip".
                if name.lowercased().hasSuffix(".zip") {
                    return name
                }
                return "\(name).zip"
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Protected Backup \(formatter.string(from: now)).zip"
    }

    static func uniqueArchiveURL(in directory: URL, sources: [URL], now: Date = Date()) -> URL {
        let fm = FileManager.default
        let base = archiveBaseName(for: sources, now: now)
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(base)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Tree walking

    private static func uniqueTopLevelName(_ name: String, used: inout Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func addTree(url: URL,
                                archivePath: String,
                                writer: ZipFileWriter,
                                summary: inout ProtectedZipSummary,
                                options: ZipEngineOptions,
                                progress: (String) -> Void,
                                dirStack: inout Set<String>) throws {
        let fm = FileManager.default
        // Follow symlinks (matching `zip`'s default) but keep the name the user
        // dropped. Cycles are caught with the resolved-path stack below.
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            recordSkip("“\(url.lastPathComponent)” is missing or unreadable", summary: &summary)
            return
        }

        let attributes = (try? fm.attributesOfItem(atPath: resolved.path)) ?? [:]
        let date = (attributes[.modificationDate] as? Date) ?? Date()
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            ?? (isDirectory.boolValue ? 0o755 : 0o644)

        let nameLength = archivePath.utf8.count + (isDirectory.boolValue ? 1 : 0)
        if nameLength > 0xFFFF {
            recordSkip("“\(archivePath)” has a path that is too long for a ZIP entry", summary: &summary)
            return
        }

        if isDirectory.boolValue {
            let canonical = resolved.standardizedFileURL.path
            if dirStack.contains(canonical) {
                recordSkip("“\(archivePath)” points back to a parent folder", summary: &summary)
                return
            }
            progress("Adding \(URL(fileURLWithPath: archivePath).lastPathComponent)/…")
            try writer.addDirectory(name: archivePath + "/", date: date, permissions: permissions)
            summary.directoryCount += 1

            dirStack.insert(canonical)
            defer { dirStack.remove(canonical) }

            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: resolved,
                                                      includingPropertiesForKeys: nil,
                                                      options: [])
            } catch {
                recordSkip("“\(archivePath)” couldn’t be read", summary: &summary)
                return
            }

            let sorted = children.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            for child in sorted {
                let name = child.lastPathComponent
                if SyncEngine.shouldExclude(name) { continue }
                try addTree(url: child,
                            archivePath: archivePath + "/" + name,
                            writer: writer,
                            summary: &summary,
                            options: options,
                            progress: progress,
                            dirStack: &dirStack)
            }
        } else {
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            progress("Adding \(URL(fileURLWithPath: archivePath).lastPathComponent)…")
            let bytes = try writer.addFile(name: archivePath,
                                           url: resolved,
                                           date: date,
                                           permissions: permissions,
                                           size: size,
                                           options: options)
            summary.fileCount += 1
            summary.byteCount += bytes
        }
    }

    private static func recordSkip(_ message: String, summary: inout ProtectedZipSummary) {
        summary.skippedCount += 1
        if summary.errors.count < 8 {
            summary.errors.append(message)
        }
        Log.write("zip skip: \(message)")
    }
}

// MARK: - ZIP writer

private final class ZipFileWriter {
    private struct CentralEntry {
        let name: String
        let versionNeeded: UInt16
        let flags: UInt16
        let method: UInt16
        let time: UInt16
        let date: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localOffset: UInt64
        let externalAttributes: UInt32
    }

    private let handle: FileHandle
    private let password: String
    private var entries: [CentralEntry] = []
    private var offset: UInt64 = 0

    init(handle: FileHandle, password: String) {
        self.handle = handle
        self.password = password
    }

    var entryCount: Int { entries.count }

    // MARK: Directories

    func addDirectory(name: String, date: Date, permissions: UInt16) throws {
        let nameData = Data(name.utf8)
        let dos = ZipDateTime(date)
        let external = externalAttributes(permissions: permissions, isDirectory: true)
        let localOffset = offset

        var header = Data()
        header.appendZipUInt32(0x0403_4B50)
        header.appendZipUInt16(20)
        header.appendZipUInt16(0x0800) // UTF-8 names only
        header.appendZipUInt16(0)      // stored
        header.appendZipUInt16(dos.time)
        header.appendZipUInt16(dos.date)
        header.appendZipUInt32(0)      // CRC
        header.appendZipUInt32(0)      // compressed size
        header.appendZipUInt32(0)      // uncompressed size
        header.appendZipUInt16(UInt16(nameData.count))
        header.appendZipUInt16(0)      // no extra field
        header.append(nameData)
        try write(header)

        entries.append(CentralEntry(name: name,
                                    versionNeeded: 20,
                                    flags: 0x0800,
                                    method: 0,
                                    time: dos.time,
                                    date: dos.date,
                                    crc: 0,
                                    compressedSize: 0,
                                    uncompressedSize: 0,
                                    localOffset: localOffset,
                                    externalAttributes: external))
    }

    // MARK: Files

    @discardableResult
    func addFile(name: String,
                 url: URL,
                 date: Date,
                 permissions: UInt16,
                 size: Int64,
                 options: ZipEngineOptions) throws -> Int64 {
        let nameData = Data(name.utf8)
        let dos = ZipDateTime(date)
        let external = externalAttributes(permissions: permissions, isDirectory: false)
        let localOffset = offset

        var method: UInt16 = 0
        var crc: UInt32 = 0
        var compressedData = Data()
        var uncompressedSize = UInt64(max(0, size))
        var payloadSize: UInt64 = 0
        var localZip64 = false

        if size <= Int64(options.compressionLimit) {
            // Small enough to read, checksum and (optionally) deflate in memory.
            let data = try Data(contentsOf: url)
            uncompressedSize = UInt64(data.count)
            crc = CRC32.checksum(data)
            if options.compressSmallFiles, !data.isEmpty,
               let deflated = ZipCompression.deflate(data),
               deflated.count < data.count {
                method = 8
                compressedData = deflated
            } else {
                method = 0
                compressedData = data
            }
            payloadSize = UInt64(compressedData.count)
            localZip64 = options.forceZip64
                || UInt64(12) + payloadSize >= 0xFFFF_FFFF
                || uncompressedSize >= 0xFFFF_FFFF

            let compressedSize = UInt64(12) + payloadSize
            try writeLocalHeader(nameData: nameData,
                                 dos: dos,
                                 crc: crc,
                                 method: method,
                                 compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 zip64: localZip64)
            var crypto = try writeEncryptionHeader(crc: crc)
            try writeEncrypted(compressedData, crypto: &crypto)

            entries.append(CentralEntry(name: name,
                                        versionNeeded: localZip64 ? 45 : 20,
                                        flags: 0x0801,
                                        method: method,
                                        time: dos.time,
                                        date: dos.date,
                                        crc: crc,
                                        compressedSize: compressedSize,
                                        uncompressedSize: uncompressedSize,
                                        localOffset: localOffset,
                                        externalAttributes: external))
            return Int64(uncompressedSize)
        }

        // Large file: store it uncompressed so memory stays bounded. The first
        // pass computes the CRC (needed for the local header and the ZipCrypto
        // check bytes); the second pass encrypts and writes the bytes.
        var accumulator = CRC32Accumulator()
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                accumulator.update(chunk)
            }
        }
        crc = accumulator.checksum
        let compressedSize = UInt64(12) + uncompressedSize
        localZip64 = options.forceZip64
            || compressedSize >= 0xFFFF_FFFF
            || uncompressedSize >= 0xFFFF_FFFF

        try writeLocalHeader(nameData: nameData,
                             dos: dos,
                             crc: crc,
                             method: 0,
                             compressedSize: compressedSize,
                             uncompressedSize: uncompressedSize,
                             zip64: localZip64)
        var crypto = try writeEncryptionHeader(crc: crc)

        var remaining = Int64(uncompressedSize)
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while remaining > 0 {
                let wanted = Int(min(Int64(1024 * 1024), remaining))
                guard let chunk = try input.read(upToCount: wanted), !chunk.isEmpty else { break }
                try writeEncrypted(chunk, crypto: &crypto)
                remaining -= Int64(chunk.count)
            }
        }
        if remaining != 0 {
            throw ZipEngineError.sourceChanged(name)
        }

        // Guard against a source that grew or shrank between the two passes.
        if let after = try? FileManager.default.attributesOfItem(atPath: url.path),
           let afterSize = (after[.size] as? NSNumber)?.int64Value,
           afterSize != Int64(uncompressedSize) {
            throw ZipEngineError.sourceChanged(name)
        }

        entries.append(CentralEntry(name: name,
                                    versionNeeded: localZip64 ? 45 : 20,
                                    flags: 0x0801,
                                    method: 0,
                                    time: dos.time,
                                    date: dos.date,
                                    crc: crc,
                                    compressedSize: compressedSize,
                                    uncompressedSize: uncompressedSize,
                                    localOffset: localOffset,
                                    externalAttributes: external))
        return Int64(uncompressedSize)
    }

    // MARK: Header / data writing

    private func writeLocalHeader(nameData: Data,
                                  dos: ZipDateTime,
                                  crc: UInt32,
                                  method: UInt16,
                                  compressedSize: UInt64,
                                  uncompressedSize: UInt64,
                                  zip64: Bool) throws {
        var header = Data()
        header.appendZipUInt32(0x0403_4B50)
        header.appendZipUInt16(zip64 ? 45 : 20)
        header.appendZipUInt16(0x0801) // encrypted + UTF-8
        header.appendZipUInt16(method)
        header.appendZipUInt16(dos.time)
        header.appendZipUInt16(dos.date)
        header.appendZipUInt32(crc)
        if zip64 {
            header.appendZipUInt32(0xFFFF_FFFF)
            header.appendZipUInt32(0xFFFF_FFFF)
        } else {
            header.appendZipUInt32(UInt32(compressedSize))
            header.appendZipUInt32(UInt32(uncompressedSize))
        }
        header.appendZipUInt16(UInt16(nameData.count))
        header.appendZipUInt16(zip64 ? 20 : 0)
        header.append(nameData)
        if zip64 {
            header.appendZipUInt16(0x0001)
            header.appendZipUInt16(16)
            header.appendZipUInt64(uncompressedSize)
            header.appendZipUInt64(compressedSize)
        }
        try write(header)
    }

    /// Writes the 12-byte ZipCrypto header. The last two bytes are the high
    /// word of the CRC (low byte first, as Info-ZIP writes it).
    private func writeEncryptionHeader(crc: UInt32) throws -> ZipCrypto {
        var crypto = ZipCrypto(password: password)
        var plain = [UInt8](repeating: 0, count: 12)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<10 {
            plain[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        plain[10] = UInt8((crc >> 16) & 0xFF)
        plain[11] = UInt8((crc >> 24) & 0xFF)
        var encrypted = [UInt8](repeating: 0, count: 12)
        for index in 0..<12 {
            encrypted[index] = crypto.encrypt(plain[index])
        }
        try write(Data(encrypted))
        return crypto
    }

    private func writeEncrypted(_ data: Data, crypto: inout ZipCrypto) throws {
        guard !data.isEmpty else { return }
        var encrypted = [UInt8](repeating: 0, count: data.count)
        data.withUnsafeBytes { raw in
            for index in 0..<raw.count {
                encrypted[index] = crypto.encrypt(raw[index])
            }
        }
        try write(Data(encrypted))
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    // MARK: Central directory

    func finish() throws {
        let centralStart = offset
        for entry in entries {
            try writeCentralEntry(entry)
        }
        let centralSize = offset - centralStart
        let needsZip64 = entries.contains { entry in
            entry.compressedSize >= 0xFFFF_FFFF
                || entry.uncompressedSize >= 0xFFFF_FFFF
                || entry.localOffset >= 0xFFFF_FFFF
        } || centralStart >= 0xFFFF_FFFF
          || centralSize >= 0xFFFF_FFFF
          || entries.count >= 0xFFFF

        if needsZip64 {
            let zip64Start = offset
            var record = Data()
            record.appendZipUInt32(0x0606_4B50)
            record.appendZipUInt64(44)
            record.appendZipUInt16(0x031E)
            record.appendZipUInt16(45)
            record.appendZipUInt32(0)
            record.appendZipUInt32(0)
            record.appendZipUInt64(UInt64(entries.count))
            record.appendZipUInt64(UInt64(entries.count))
            record.appendZipUInt64(centralSize)
            record.appendZipUInt64(centralStart)
            try write(record)

            var locator = Data()
            locator.appendZipUInt32(0x0706_4B50)
            locator.appendZipUInt32(0)
            locator.appendZipUInt64(zip64Start)
            locator.appendZipUInt32(1)
            try write(locator)
        }

        var end = Data()
        end.appendZipUInt32(0x0605_4B50)
        end.appendZipUInt16(0)
        end.appendZipUInt16(0)
        end.appendZipUInt16(needsZip64 ? 0xFFFF : UInt16(entries.count))
        end.appendZipUInt16(needsZip64 ? 0xFFFF : UInt16(entries.count))
        end.appendZipUInt32(needsZip64 ? 0xFFFF_FFFF : UInt32(centralSize))
        end.appendZipUInt32(needsZip64 ? 0xFFFF_FFFF : UInt32(centralStart))
        end.appendZipUInt16(0)
        try write(end)
    }

    private func writeCentralEntry(_ entry: CentralEntry) throws {
        let nameData = Data(entry.name.utf8)
        let needsSize64 = entry.compressedSize >= 0xFFFF_FFFF || entry.uncompressedSize >= 0xFFFF_FFFF
        let needsOffset64 = entry.localOffset >= 0xFFFF_FFFF
        let zip64 = needsSize64 || needsOffset64

        var extraData = Data()
        if entry.uncompressedSize >= 0xFFFF_FFFF {
            extraData.appendZipUInt64(entry.uncompressedSize)
        }
        if entry.compressedSize >= 0xFFFF_FFFF {
            extraData.appendZipUInt64(entry.compressedSize)
        }
        if needsOffset64 {
            extraData.appendZipUInt64(entry.localOffset)
        }

        var extra = Data()
        if !extraData.isEmpty {
            extra.appendZipUInt16(0x0001)
            extra.appendZipUInt16(UInt16(extraData.count))
            extra.append(extraData)
        }

        var header = Data()
        header.appendZipUInt32(0x0201_4B50)
        header.appendZipUInt16(0x031E) // made by: Unix, ZIP 3.0
        header.appendZipUInt16(zip64 ? 45 : entry.versionNeeded)
        header.appendZipUInt16(entry.flags)
        header.appendZipUInt16(entry.method)
        header.appendZipUInt16(entry.time)
        header.appendZipUInt16(entry.date)
        header.appendZipUInt32(entry.crc)
        header.appendZipUInt32(entry.compressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(entry.compressedSize))
        header.appendZipUInt32(entry.uncompressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(entry.uncompressedSize))
        header.appendZipUInt16(UInt16(nameData.count))
        header.appendZipUInt16(UInt16(extra.count))
        header.appendZipUInt16(0) // comment length
        header.appendZipUInt16(0) // disk number
        header.appendZipUInt16(0) // internal attributes
        header.appendZipUInt32(entry.externalAttributes)
        header.appendZipUInt32(needsOffset64 ? 0xFFFF_FFFF : UInt32(entry.localOffset))
        header.append(nameData)
        header.append(extra)
        try write(header)
    }

    private func externalAttributes(permissions: UInt16, isDirectory: Bool) -> UInt32 {
        let type: UInt32 = isDirectory ? 0o040000 : 0o100000
        let mode = type | UInt32(permissions & 0o7777)
        return (mode << 16) | (isDirectory ? 0x10 : 0)
    }
}

// MARK: - ZipCrypto

private struct ZipCrypto {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    init(password: String) {
        for byte in password.utf8 {
            update(byte)
        }
    }

    mutating func encrypt(_ byte: UInt8) -> UInt8 {
        let temp = (key2 | 2) & 0xFFFF
        let encrypted = byte ^ UInt8(((temp &* (temp ^ 1)) >> 8) & 0xFF)
        update(byte)
        return encrypted
    }

    private mutating func update(_ byte: UInt8) {
        key0 = CRC32.update(key0, byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 13_477_5813 &+ 1
        key2 = CRC32.update(key2, UInt8((key1 >> 24) & 0xFF))
    }
}

// MARK: - Checksums / compression / dates

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func update(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    static func checksum(_ data: Data) -> UInt32 {
        var accumulator = CRC32Accumulator()
        accumulator.update(data)
        return accumulator.checksum
    }
}

private struct CRC32Accumulator {
    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            for byte in raw {
                value = CRC32.update(value, byte)
            }
        }
    }

    var checksum: UInt32 { value ^ 0xFFFF_FFFF }
}

private enum ZipCompression {
    /// Raw DEFLATE, which is what ZIP method 8 stores (COMPRESSION_ZLIB).
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 1000 + 1024
        var output = Data(count: capacity)
        let produced = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destination = destination.bindMemory(to: UInt8.self).baseAddress,
                      let source = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(destination,
                                                 capacity,
                                                 source,
                                                 data.count,
                                                 nil,
                                                 COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { return nil }
        output.count = produced
        return output
    }
}

private struct ZipDateTime {
    let time: UInt16
    let date: UInt16

    init(_ date: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        self.time = UInt16((hour << 11) | (minute << 5) | (second / 2))
        self.date = UInt16(((year - 1980) << 9) | (month << 5) | day)
    }
}

private extension Data {
    mutating func appendZipUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendZipUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendZipUInt64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
