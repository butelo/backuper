import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class PopoverViewState: ObservableObject {
    @Published var isTargeted = false
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject var viewState: PopoverViewState

    private var isTargeted: Bool { viewState.isTargeted }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    destinationCard
                    dropZone
                    if state.isSyncing {
                        syncingRow
                    }
                    if let notice = state.notice {
                        noticeBar(notice)
                    }
                    itemsSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewState.isTargeted) { providers in
            state.handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backuper")
                    .font(.system(size: 13, weight: .semibold))
                Text(state.lastSyncText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            Button(action: { state.openDestination() }) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Open the cloud backup folder")

            Menu {
                Button("Restore from Backup…") { state.showRestoreWindow() }
                    .disabled(state.archive.isEmpty)
                Divider()
                Button("Change Cloud Folder…") { state.chooseDestination() }
                Toggle("Launch at Login", isOn: Binding(get: { state.launchAtLogin },
                                                       set: { state.setLaunchAtLogin($0) }))
                Divider()
                Button("Quit Backuper") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Destination

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "cloud")
                    .font(.system(size: 9))
                Text("CLOUD FOLDER")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                Spacer()
                Button("Change…") { state.chooseDestination() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .foregroundColor(.secondary)

            if state.destinationPath.isEmpty {
                Text("Not set — choose a folder inside OneDrive, Dropbox, Google Drive, iCloud Drive…")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            } else {
                Text(state.destinationDisplayPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let provider = state.destinationProviderName {
                    Label("Syncing via \(provider)", systemImage: "checkmark.icloud")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                } else {
                    Label("This folder isn’t inside a known cloud-sync folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(.orange)
                }
                if !state.archive.isEmpty {
                    Label("\(state.archive.count) item\(state.archive.count == 1 ? "" : "s") restorable · metadata in the cloud folder",
                          systemImage: "checkmark.icloud")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.02))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.40),
                              style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [6, 4]))
            VStack(spacing: 5) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 21))
                    .foregroundColor(isTargeted ? .accentColor : .secondary)
                Text(isTargeted ? "Drop to back up" : "Drag files or folders here")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Copied into your cloud folder")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 100)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private var syncingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            Text(state.activity ?? "Syncing…")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func noticeBar(_ notice: Notice) -> some View {
        let color: Color = notice.kind == .error ? .red : (notice.kind == .success ? .green : .accentColor)
        let icon = notice.kind == .error
            ? "exclamationmark.circle.fill"
            : (notice.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(notice.text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.10)))
    }

    // MARK: - Items

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TRACKED ITEMS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.secondary)
                Spacer()
                if !state.items.isEmpty {
                    Text(state.itemCountText)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
            }

            if state.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(item: item, state: state)
                        if index < state.items.count - 1 {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundColor(.secondary.opacity(0.6))
            Text("Nothing tracked yet")
                .font(.system(size: 12, weight: .medium))
            Text(state.archive.isEmpty
                 ? "Drop a file or folder above. Backuper keeps a copy in your cloud folder and re-checks it every day."
                 : "This cloud folder already holds \(state.archiveCountText). Use Restore to bring them back.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !state.archive.isEmpty {
                Button("Restore from Backup…") { state.showRestoreWindow() }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { state.dailyEnabled },
                                     set: { state.setDailyEnabled($0) })) {
                    Text("Daily backup")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                DatePicker("", selection: Binding(get: { state.dailyTime },
                                                  set: { state.setDailyTime($0) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(width: 72)
                    .controlSize(.small)
                    .disabled(!state.dailyEnabled)

                Spacer(minLength: 4)

                Button(action: { state.syncAll() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync Now")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!state.canSync || state.isSyncing)
            }

            HStack(spacing: 6) {
                Text(state.nextSyncText)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Restore…") { state.showRestoreWindow() }
                    .buttonStyle(.link)
                    .font(.system(size: 9.5))
                    .disabled(state.archive.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.035))
    }
}

struct ItemRow: View {
    let item: TrackedItem
    @ObservedObject var state: AppState

    private var statusColor: Color {
        switch item.lastStatus {
        case .ok: return .green
        case .pending: return .secondary
        case .failed: return .red
        case .missing: return .orange
        }
    }

    private var statusText: String {
        switch item.lastStatus {
        case .pending:
            return "Waiting to copy"
        case .ok:
            guard let date = item.lastSyncAt else { return "Up to date" }
            return "Up to date · \(Format.relative(date))"
        case .failed:
            return item.lastMessage ?? "Last backup failed"
        case .missing:
            return "Original no longer exists"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.sourcePath))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.sourcePath)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.lastMessage ?? statusText)
                }
            }

            Spacer(minLength: 4)

            Menu {
                Button("Sync Now") { state.sync(ids: [item.id]) }
                Button("Restore to Original Location…") { state.restoreItem(item) }
                Button("Show in Backup Folder") { state.reveal(item) }
                Divider()
                Button("Stop Syncing", role: .destructive) { state.remove(item) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }
}
