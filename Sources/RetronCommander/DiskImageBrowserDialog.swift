import AppKit
import SwiftUI

struct DiskImageBrowserDialog: View {
    let image: URL
    @Environment(\.dismiss) private var dismiss
    @State private var service: DiskImageService?
    @State private var entries: [DiskImageService.Entry] = []
    @State private var selected: Set<String> = []
    @State private var path = ""
    @State private var error: String?
    @State private var isLoading = true
    @State private var isExtracting = false
    @State private var extractionProgress = 0.0
    @State private var extractionOperation: Task<Void, Error>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                Text(image.lastPathComponent).font(.headline)
                if let service { Text(service.filesystemName).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(entries.count) items").foregroundStyle(.secondary)
            }
            .padding(12)
            HStack(spacing: 8) {
                Button("Up") { navigateUp() }.disabled(path.isEmpty)
                Text(path.isEmpty ? "/" : "/" + path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Refresh") { load() }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Table(entries, selection: $selected) {
                TableColumn("Name") { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        Text(item.name).lineLimit(1)
                    }
                }.width(min: 220, ideal: 360)
                TableColumn("Size") { item in
                    Text(item.isDirectory ? "<DIR>" : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 80, ideal: 110)
                TableColumn("Attributes") { item in Text(attributeText(item.attributes)) }
                    .width(min: 90, ideal: 120)
                TableColumn("Modified") { item in Text(item.modified?.formatted(date: .numeric, time: .shortened) ?? "") }
                    .width(min: 140, ideal: 180)
            }
            .overlay {
                if isLoading { ProgressView("Mounting disk image…") }
                else if let error { ContentUnavailableView("Could Not Read Image", systemImage: "externaldrive.badge.exclamationmark", description: Text(error)) }
                else if entries.isEmpty { ContentUnavailableView("Empty Directory", systemImage: "folder") }
            }
            .onTapGesture(count: 2) { openSelectedDirectory() }
            if isExtracting {
                HStack(spacing: 10) {
                    ProgressView(value: extractionProgress).frame(maxWidth: .infinity)
                    Text("\(Int(extractionProgress * 100))%")
                        .font(.system(size: 11, design: .monospaced)).frame(width: 38, alignment: .trailing)
                    Button("Cancel") { extractionOperation?.cancel() }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            HStack {
                Text(selected.isEmpty ? "Choose files or directories to extract." : "\(selected.count) selected")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Extract Selected…") { extractSelected() }.disabled(selected.isEmpty || isLoading || isExtracting)
                Button("Extract Directory…") { extract(entries) }.disabled(entries.isEmpty || isLoading || isExtracting)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { load() }
        .alert("FAT Image", isPresented: Binding(get: { error != nil && service != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        error = nil
        do {
            let reader = try service ?? DiskImageService(image: image)
            service = reader
            entries = try reader.list(path: path)
            selected.removeAll()
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
        isLoading = false
    }

    private func navigateUp() {
        path = path.split(separator: "/").dropLast().joined(separator: "/")
        load()
    }

    private func openSelectedDirectory() {
        guard let chosen = entries.first(where: { selected.contains($0.id) }), chosen.isDirectory else { return }
        path = chosen.path
        load()
    }

    private func extractSelected() { extract(entries.filter { selected.contains($0.id) }) }

    private func extract(_ items: [DiskImageService.Entry]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose extraction destination"
        panel.prompt = "Extract"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url, let service else { return }
        isExtracting = true
        extractionProgress = 0
        let (updates, continuation) = AsyncStream<Double>.makeStream()
        extractionOperation = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            try service.extract(items, to: destination) { completed, total, _ in
                continuation.yield(total == 0 ? 1 : min(1, Double(completed) / Double(total)))
                return !Task.isCancelled
            }
        }
        Task { @MainActor in
            for await value in updates { extractionProgress = value }
            do { try await extractionOperation?.value }
            catch { self.error = error.localizedDescription }
            extractionOperation = nil
            isExtracting = false
        }
    }

    private func attributeText(_ attributes: UInt8) -> String {
        var values: [String] = []
        if attributes & 0x01 != 0 { values.append("R") }
        if attributes & 0x02 != 0 { values.append("H") }
        if attributes & 0x04 != 0 { values.append("S") }
        if attributes & 0x20 != 0 { values.append("A") }
        return values.joined(separator: " ")
    }
}
