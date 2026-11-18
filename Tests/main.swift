import Foundation

// End-to-end tests for the non-UI parts of Backuper. They run against a fake
// cloud folder inside the workspace, not the real cloud folder.

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/tests/run", isDirectory: true)
try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)

let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
let fakeCloud = root.appendingPathComponent("FakeCloud/Backuper", isDirectory: true)
try! fm.createDirectory(at: fakeCloud, withIntermediateDirectories: true)

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label)")
        failures.append(label)
    }
}

func write(_ text: String, to url: URL, mtimeOffset: TimeInterval = 0) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
    if mtimeOffset != 0 {
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(mtimeOffset)], ofItemAtPath: url.path)
    }
}

func read(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - Fixtures

let project = sourceRoot.appendingPathComponent("Project Alpha", isDirectory: true)
let docs = project.appendingPathComponent("docs", isDirectory: true)
let assets = project.appendingPathComponent("assets", isDirectory: true)
try! fm.createDirectory(at: docs, withIntermediateDirectories: true)
try! fm.createDirectory(at: assets, withIntermediateDirectories: true)

write("Quarterly plan v1\n", to: project.appendingPathComponent("plan.txt"))
write("Meeting notes\n", to: docs.appendingPathComponent("notes.md"))
write("fake binary payload\n", to: assets.appendingPathComponent("logo.bin"))
write("junk", to: project.appendingPathComponent(".DS_Store"))
write("lock", to: project.appendingPathComponent("~$lock.docx"))

let report = sourceRoot.appendingPathComponent("report.pdf")
write("report v1\n", to: report)

var projectItem = TrackedItem(sourcePath: project.path, relativePath: "Project Alpha", isDirectory: true)
var reportItem = TrackedItem(sourcePath: report.path, relativePath: "report.pdf", isDirectory: false)

// MARK: - 1. First backup

print("\n1. First backup copies files and writes metadata")
var projectResult = SyncEngine.sync(item: projectItem, destinationRoot: fakeCloud)
var reportResult = SyncEngine.sync(item: reportItem, destinationRoot: fakeCloud)
check(projectResult.fatalError == nil && projectResult.fileErrors.isEmpty, "project sync has no errors")
check(projectResult.filesCopied == 3, "copies 3 project files (got \(projectResult.filesCopied))")
check(projectResult.totalFiles == 3, "counts 3 total files (got \(projectResult.totalFiles))")
check(reportResult.filesCopied == 1, "copies report.pdf")
check(fm.fileExists(atPath: fakeCloud.appendingPathComponent("Project Alpha/docs/notes.md").path), "nested folder copied")
check(!fm.fileExists(atPath: fakeCloud.appendingPathComponent("Project Alpha/.DS_Store").path), "skips .DS_Store")
check(!fm.fileExists(atPath: fakeCloud.appendingPathComponent("Project Alpha/~$lock.docx").path), "skips Office lock file")
check(read(fakeCloud.appendingPathComponent("Project Alpha/plan.txt")) == "Quarterly plan v1\n", "file content preserved")

projectItem.lastFileCount = projectResult.totalFiles
projectItem.lastByteCount = projectResult.totalBytes
projectItem.lastSyncAt = Date()
reportItem.lastFileCount = reportResult.totalFiles
reportItem.lastByteCount = reportResult.totalBytes
reportItem.lastSyncAt = Date()
projectItem.lastStatus = .ok
reportItem.lastStatus = .ok

let manifest = Catalog.merged(with: [projectItem, reportItem], existing: nil)
try! Catalog.save(manifest, to: fakeCloud)
let loaded = try! Catalog.load(from: fakeCloud)
check(loaded?.records.count == 2, "manifest holds 2 records")
let sidecarNames = (try? fm.contentsOfDirectory(atPath: Catalog.recordsDir(for: fakeCloud).path)) ?? []
check(sidecarNames.filter { $0.hasSuffix(".json") }.count == 2, "writes one per-item metadata record per item")
let recoveryFile = Catalog.metadataDir(for: fakeCloud).appendingPathComponent(Catalog.recoveryName)
check(fm.fileExists(atPath: recoveryFile.path), "writes a human-readable recovery index")
let recoveryText = read(recoveryFile) ?? ""
check(recoveryText.contains(project.path), "recovery index lists the original path")
check(recoveryText.contains("Project Alpha"), "recovery index lists the item")
let projectRecord = loaded!.records.first { $0.id == projectItem.id }!
check(projectRecord.originalPath == project.path, "manifest stores the original absolute path")
let expectedFromHome = String(project.path.dropFirst(fm.homeDirectoryForCurrentUser.path.count + 1))
check(projectRecord.originalPathFromHome == expectedFromHome,
      "manifest stores a home-relative path (got \(projectRecord.originalPathFromHome ?? "nil"))")
check(projectRecord.isDirectory, "manifest knows it is a directory")
check(manifest.records.allSatisfy { $0.hostName == ProcessInfo.processInfo.hostName }, "manifest stores host name")
check(fm.fileExists(atPath: fakeCloud.appendingPathComponent("_Backuper/README.txt").path), "writes a human-readable metadata README")

let copiedPlan = fakeCloud.appendingPathComponent("Project Alpha/plan.txt")
check(Xattr.string(Xattr.originalPath, at: copiedPlan) == project.appendingPathComponent("plan.txt").path,
      "per-file xattr stores original path")
check(Xattr.string(Xattr.itemID, at: copiedPlan) == projectItem.id.uuidString,
      "per-file xattr stores the item id")
check(Xattr.string(Xattr.originalPath, at: fakeCloud.appendingPathComponent("Project Alpha")) == project.path,
      "top-level folder xattr stores original path")

// MARK: - 2. Unchanged files are skipped

print("\n2. A second run skips unchanged files")
projectResult = SyncEngine.sync(item: projectItem, destinationRoot: fakeCloud)
reportResult = SyncEngine.sync(item: reportItem, destinationRoot: fakeCloud)
check(projectResult.filesCopied == 0, "project: nothing copied (got \(projectResult.filesCopied))")
check(projectResult.filesSkipped == 3, "project: 3 files skipped (got \(projectResult.filesSkipped))")
check(reportResult.filesCopied == 0, "report: nothing copied")
check(reportResult.filesSkipped == 1, "report: file skipped")

// MARK: - 3. Changed and new files are picked up

print("\n3. A changed file and a new file are copied")
write("Quarterly plan v2\n", to: project.appendingPathComponent("plan.txt"), mtimeOffset: 5)
write("New extra note\n", to: docs.appendingPathComponent("extra.txt"), mtimeOffset: 5)
projectResult = SyncEngine.sync(item: projectItem, destinationRoot: fakeCloud)
check(projectResult.filesCopied == 2, "copies exactly the changed + new file (got \(projectResult.filesCopied))")
check(read(fakeCloud.appendingPathComponent("Project Alpha/plan.txt")) == "Quarterly plan v2\n", "updated content")
check(read(fakeCloud.appendingPathComponent("Project Alpha/docs/extra.txt")) == "New extra note\n", "new file appears")
check(projectResult.totalFiles == 4, "totals grow to 4 files (got \(projectResult.totalFiles))")

// MARK: - 4. A newer cloud copy is not clobbered

print("\n4. A newer destination copy is left alone")
let cloudReport = fakeCloud.appendingPathComponent("report.pdf")
write("edited in the cloud\n", to: cloudReport, mtimeOffset: 60)
reportResult = SyncEngine.sync(item: reportItem, destinationRoot: fakeCloud)
check(reportResult.filesCopied == 0, "older local file does not overwrite newer cloud file")
check(read(cloudReport) == "edited in the cloud\n", "cloud edit survives")
try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: cloudReport.path)

// MARK: - 5. Missing source is reported

print("\n5. A missing source is reported, not silently removed")
try! fm.removeItem(at: project)
projectResult = SyncEngine.sync(item: projectItem, destinationRoot: fakeCloud)
check(projectResult.sourceMissing, "sync result says the source is missing")
check(fm.fileExists(atPath: fakeCloud.appendingPathComponent("Project Alpha/plan.txt").path),
      "backup copy is left untouched when the source disappears")

// MARK: - 6. Restore to the original location

print("\n6. Restore puts the folder back where it came from")
var restoreResult = RestoreEngine.restore(record: projectRecord, destinationRoot: fakeCloud, policy: .keepBoth)
check(restoreResult.succeeded, "restore succeeded")
check(restoreResult.restoredPath == project.path, "restored to the original path")
check(read(project.appendingPathComponent("plan.txt")) == "Quarterly plan v2\n", "restored content is the backed-up version")
check(fm.fileExists(atPath: project.appendingPathComponent("docs/extra.txt").path), "restored nested files")
check(restoreResult.filesCopied == 4, "restore counted 4 files (got \(restoreResult.filesCopied))")

// MARK: - 7. Keep both when something already exists

print("\n7. Keep-both restore never overwrites")
restoreResult = RestoreEngine.restore(record: projectRecord, destinationRoot: fakeCloud, policy: .keepBoth)
let restoredSibling = sourceRoot.appendingPathComponent("Project Alpha (restored)")
check(restoreResult.succeeded, "second restore succeeded")
check(restoreResult.restoredPath == restoredSibling.path, "created a (restored) sibling")
check(fm.fileExists(atPath: project.appendingPathComponent("plan.txt").path), "original still present")
check(fm.fileExists(atPath: restoredSibling.appendingPathComponent("plan.txt").path), "sibling copy present")

// MARK: - 8. Replace restores over the original, safely

print("\n8. Replace restores over the original")
write("local edit that will be replaced\n", to: project.appendingPathComponent("plan.txt"), mtimeOffset: 120)
restoreResult = RestoreEngine.restore(record: projectRecord, destinationRoot: fakeCloud, policy: .replace)
check(restoreResult.succeeded, "replace restore succeeded")
check(restoreResult.restoredPath == project.path, "restored to the original path")
check(read(project.appendingPathComponent("plan.txt")) == "Quarterly plan v2\n", "backup content replaced the local edit")
let leftovers = try! fm.contentsOfDirectory(atPath: sourceRoot.path).filter { $0.contains("backuper-old") }
check(leftovers.isEmpty, "no temporary replace folders left behind")

// MARK: - 9. Manifest merge keeps records from other Macs / old items

print("\n9. Manifest merging preserves records it does not track")
let foreign = BackupRecord(id: UUID(),
                           relativePath: "Other Mac File.txt",
                           originalPath: "/Users/someone/Desktop/Other Mac File.txt",
                           originalPathFromHome: "Desktop/Other Mac File.txt",
                           isDirectory: false,
                           addedAt: Date(),
                           lastSyncAt: Date(),
                           hostName: "another-mac.local",
                           userName: "someone",
                           fileCount: 1,
                           byteCount: 42)
var mergedManifest = Catalog.merged(with: [projectItem, reportItem], existing: loaded)
mergedManifest.records.append(foreign)
try! Catalog.save(mergedManifest, to: fakeCloud)

let withForeign = try! Catalog.load(from: fakeCloud)!
check(withForeign.records.count == 3, "merged manifest has 3 records")
let mergedAgain = Catalog.merged(with: [projectItem], existing: withForeign)
check(mergedAgain.records.contains { $0.id == foreign.id }, "foreign record survives a merge")
let resolvedForeign = mergedAgain.records.first { $0.id == foreign.id }!.resolvedOriginalURL()
check(resolvedForeign.path == fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Other Mac File.txt").path,
      "home-relative path resolves on the current Mac")

// MARK: - 10. Name collisions are avoided

print("\n10. Untracked existing files are not overwritten")
write("preexisting\n", to: fakeCloud.appendingPathComponent("Existing.txt"))
let before = try! fm.contentsOfDirectory(atPath: fakeCloud.path).sorted()
check(before.contains("Existing.txt"), "fixture exists")
check(!SyncEngine.shouldExclude("Existing.txt"), "ordinary files are not excluded")

// MARK: - 11. Cloud-only recovery on a "fresh Mac"

print("\n11. A fresh Mac can recover from a copy of the cloud folder")
let newMacRoot = root.appendingPathComponent("NewMac/CloudDrive", isDirectory: true)
let cloudBackup = newMacRoot.appendingPathComponent("Backuper", isDirectory: true)
try! fm.createDirectory(at: newMacRoot, withIntermediateDirectories: true)
try? fm.removeItem(at: cloudBackup)
try! fm.copyItem(at: fakeCloud, to: cloudBackup)

let discovered = CloudFolderLocator.findExistingBackupDestination(in: [newMacRoot])
check(discovered?.path == cloudBackup.path, "auto-discovers <cloud folder>/Backuper")
let cloudManifest = try! Catalog.load(from: cloudBackup)
check(cloudManifest?.records.count == 3, "cloud copy carries all 3 records")
check(fm.fileExists(atPath: Catalog.manifestURL(for: cloudBackup).path), "manifest present in cloud copy")

// Simulate a damaged or lost index: the per-item records must rebuild it.
try! fm.removeItem(at: Catalog.manifestURL(for: cloudBackup))
let rebuilt = try! Catalog.load(from: cloudBackup)
check(rebuilt?.records.count == 3, "rebuilds manifest from per-item records")
check(fm.fileExists(atPath: Catalog.manifestURL(for: cloudBackup).path), "rewrites the missing manifest")

// Restore from the cloud copy after the original disappears.
try? fm.removeItem(at: project)
let cloudProjectRecord = rebuilt!.records.first { $0.relativePath == "Project Alpha" }!
let cloudRestore = RestoreEngine.restore(record: cloudProjectRecord, destinationRoot: cloudBackup, policy: .keepBoth)
check(cloudRestore.succeeded, "restores from the relocated cloud copy")
check(cloudRestore.restoredPath == project.path, "restores to the recorded original path")
check(read(project.appendingPathComponent("plan.txt")) == "Quarterly plan v2\n", "restored cloud content is correct")

let emptyCloudRoot = root.appendingPathComponent("NewMac/EmptyCloud", isDirectory: true)
try! fm.createDirectory(at: emptyCloudRoot, withIntermediateDirectories: true)
check(CloudFolderLocator.findExistingBackupDestination(in: [emptyCloudRoot]) == nil,
      "does not invent a destination when there is no metadata")

// MARK: - 12. Cloud provider detection

print("\n12. Cloud folder detection")
let home = fm.homeDirectoryForCurrentUser
check(CloudFolderLocator.providerName(for: home.appendingPathComponent("Dropbox/Backuper")) == "Dropbox",
      "detects Dropbox")
check(CloudFolderLocator.providerName(for: home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/Backuper")) == "OneDrive",
      "detects OneDrive under CloudStorage")
check(CloudFolderLocator.providerName(for: home.appendingPathComponent("Google Drive/My Drive/Backuper")) == "Google Drive",
      "detects Google Drive")
check(CloudFolderLocator.providerName(for: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Backuper")) == "iCloud Drive",
      "detects iCloud Drive")
check(CloudFolderLocator.providerName(for: home.appendingPathComponent("Downloads/backuper")) == nil,
      "does not mislabel ordinary folders")
check(CloudFolderLocator.findExistingBackupDestination(in: [home.appendingPathComponent("MissingCloudRoot")]) == nil,
      "ignores cloud roots that do not exist")

// MARK: - Summary

print("\n\(checks - failures.count)/\(checks) checks passed")
if failures.isEmpty {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("FAILED:")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
