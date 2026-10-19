import AppKit
import Darwin
import SwiftUI

private struct TrashEntry: Identifiable, Hashable {
    let url: URL
    let byteSize: Int64
    let modifiedAt: Date?
    let isDirectory: Bool

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
    var sizeText: String { isDirectory ? "<DIR>" : ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
}

struct TrashRecoveryDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TrashEntry] = []
    @State private var selected: Set<String> = []
    @State private var status = "Choose items to restore from Trash."
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "trash")
                Text("Restore items from macOS Trash").font(.headline)
                Spacer()
                Button("Refresh") { load() }.disabled(isWorking)
            }.padding(12)
            Table(entries, selection: $selected) {
                TableColumn("Name") { entry in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(entry.name).lineLimit(1)
                    }
                }
                TableColumn("Size", value: \.sizeText).width(min: 60, ideal: 82)
                TableColumn("Removed", value: \.modifiedText).width(min: 110, ideal: 150)
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Button("Restore…") { restore() }.disabled(selected.isEmpty || isWorking)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(10)
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear(perform: load)
    }

    private func load() {
        guard !isWorking else { return }
        error = nil
        let uid = String(getuid())
        var roots: [URL] = []
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            roots.append(trash)
        }
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            roots.append(volume.appendingPathComponent(".Trashes", isDirectory: true).appendingPathComponent(uid, isDirectory: true))
        }
        var unique: [String: TrashEntry] = [:]
        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
                unique[url.standardizedFileURL.path] = TrashEntry(
                    url: url,
                    byteSize: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate,
                    isDirectory: values.isDirectory ?? false
                )
            }
        }
        entries = unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selected.formIntersection(Set(entries.map(\.id)))
        status = entries.isEmpty
            ? "Trash is empty or its contents are not accessible. This restores trashed items only; permanently deleted data is not scanned."
            : "\(entries.count) item(s) · permanently deleted files are not scanned."
    }

    private func restore() {
        let sources = entries.filter { selected.contains($0.id) }.map(\.url)
        guard !sources.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a restore destination"
        panel.prompt = "Restore Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isWorking = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let restored = try FileTransferService.transfer(
                    sources: sources,
                    to: destination,
                    move: true,
                    collisions: .keepBoth
                )
                await MainActor.run {
                    isWorking = false
                    load()
                    selected.removeAll()
                    status = "Restored \(restored.count) item(s) to \(destination.path)."
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    load()
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private extension TrashEntry {
    var modifiedText: String { modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "" }
}
