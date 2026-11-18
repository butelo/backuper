import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class RestoreViewState: ObservableObject {
    @Published var selected = Set<UUID>()
    @Published var policy: RestorePolicy = .keepBoth
    @Published var isRestoring = false
    @Published var progressText = ""
    @Published var results: [RestoreItemResult] = []
    @Published var didLoad = false
}

struct RestoreView: View {
    @ObservedObject var state: AppState
    @ObservedObject var viewState: RestoreViewState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.archive.isEmpty {
                emptyState
            } else {
                list
            }
            if viewState.isRestoring {
                progressBar
            }
            if !viewState.results.isEmpty {
                resultBanner
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            state.reloadArchive()
            if !viewState.didLoad || viewState.selected.isEmpty {
                viewState.didLoad = true
                viewState.selected = Set(state.archive.map(\.id))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Restore from Backup")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(state.archiveCountText) · \(state.destinationDisplayPath)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Metadata is read from _Backuper inside the cloud folder", systemImage: "checkmark.icloud")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Refresh") {
                state.reloadArchive()
                viewState.selected = Set(state.archive.map(\.id))
                viewState.results = []
            }
            .controlSize(.small)
            .disabled(viewState.isRestoring)
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.archive) { record in
                    row(for: record)
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private func row(for record: BackupRecord) -> some View {
        let original = state.resolvedOriginalPath(for: record)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { viewState.selected.contains(record.id) },
                                     set: { include in
                                         if include { viewState.selected.insert(record.id) }
                                         else { viewState.selected.remove(record.id) }
                                     }))
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(nsImage: icon(for: record))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(record.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.isDirectory ? "folder" : "file")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Text("→ " + Format.abbreviatedPath(original))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(original)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(record.byteCount > 0 ? Format.bytes(record.byteCount) : "—")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if let last = record.lastSyncAt {
                    Text(Format.relative(last))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Button { state.reveal(record) } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Show the backup copy in the cloud folder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func icon(for record: BackupRecord) -> NSImage {
        if let root = state.destinationURL {
            let url = root.appendingPathComponent(record.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return NSWorkspace.shared.icon(for: record.isDirectory ? .folder : .data)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.6))
            Text("No backup metadata found")
                .font(.system(size: 13, weight: .medium))
            Text("Choose a synced cloud folder that contains a _Backuper/manifest.json, or let Backuper back something up first.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose Cloud Folder…") { state.chooseDestination() }
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(viewState.progressText.isEmpty ? "Restoring…" : viewState.progressText)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    private var resultBanner: some View {
        let restored = viewState.results.filter { $0.succeeded }.count
        let failed = viewState.results.count - restored
        let color: Color = failed == 0 ? .green : .orange
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(failed == 0
                     ? "Restored \(restored) item\(restored == 1 ? "" : "s")."
                     : "Restored \(restored) of \(viewState.results.count) items. \(failed) failed.")
                    .font(.system(size: 11, weight: .medium))
                if let firstFailure = viewState.results.first(where: { !$0.succeeded })?.error {
                    Text(firstFailure)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Dismiss") { viewState.results = [] }
                .buttonStyle(.link)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
    }

    private var footer: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button("Select All") { viewState.selected = Set(state.archive.map(\.id)) }
                    .controlSize(.small)
                Button("Select None") { viewState.selected.removeAll() }
                    .controlSize(.small)

                Spacer()

                Text("If files exist:")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                Picker("", selection: $viewState.policy) {
                    ForEach(RestorePolicy.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)

                Button(action: restoreSelected) {
                    Text("Restore \(viewState.selected.count) Item\(viewState.selected.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewState.selected.isEmpty || viewState.isRestoring)
            }

            HStack(spacing: 6) {
                if viewState.policy == .replace {
                    Label("Existing files at the original locations will be replaced.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(.orange)
                } else {
                    Label("Existing files are kept; restored copies get a “(restored)” suffix.", systemImage: "info.circle")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let error = state.archiveError {
                    Text(error)
                        .font(.system(size: 9.5))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.035))
    }

    private func restoreSelected() {
        guard let root = state.destinationURL, !viewState.isRestoring else { return }
        let records = state.archive.filter { viewState.selected.contains($0.id) }
        guard !records.isEmpty else { return }

        viewState.isRestoring = true
        viewState.progressText = "Preparing…"
        viewState.results = []
        let chosenPolicy = viewState.policy

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = RestoreEngine.restore(records: records,
                                                destinationRoot: root,
                                                policy: chosenPolicy) { note in
                DispatchQueue.main.async { viewState.progressText = note }
            }
            DispatchQueue.main.async {
                viewState.results = outcome
                viewState.isRestoring = false
                viewState.progressText = ""
                state.reloadArchive()
                Log.write("restore batch finished: \(outcome.filter { $0.succeeded }.count)/\(outcome.count) ok")
            }
        }
    }
}
