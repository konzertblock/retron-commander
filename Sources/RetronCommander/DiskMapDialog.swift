import SwiftUI

struct DiskMapDialog: View {
    struct Folder: Identifiable {
        let url: URL
        let bytes: Int64
        let files: Int
        var id: String { url.path }
    }

    private struct Tile: Identifiable {
        let folder: Folder
        let rect: CGRect
        var id: String { folder.id }
    }

    let root: URL
    let onOpenInApp: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [Folder] = []
    @State private var isScanning = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Map").font(.headline)
                    Text(root.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isScanning { ProgressView("Scanning…") }
            }.padding(.horizontal, 12).padding(.top, 12)

            if let error {
                ContentUnavailableView("Could Not Scan Folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !isScanning {
                let total = folders.reduce(Int64(0)) { $0 + $1.bytes }
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(Self.layout(folders, in: geometry.size).enumerated()), id: \.element.id) { index, tile in
                            VStack(alignment: .leading, spacing: 4) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if tile.rect.width > 78 && tile.rect.height > 48 {
                                        Text(tile.folder.url.lastPathComponent).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                                        Text(ByteCountFormatter.string(fromByteCount: tile.folder.bytes, countStyle: .file)).font(.system(size: 10))
                                        if tile.rect.height > 78 { Text("\(tile.folder.files) files").font(.system(size: 9)) }
                                    }
                                }
                                .padding(6)
                                .frame(width: max(1, tile.rect.width - 1), height: max(1, tile.rect.height - 1), alignment: .topLeading)
                                .background(Color(hue: Double(index % 12) / 12, saturation: 0.3, brightness: 0.93))
                                .contentShape(Rectangle())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onOpenInApp(tile.folder.url) }
                            .contextMenu {
                                Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tile.folder.url]) }
                            }
                            .position(x: tile.rect.midX, y: tile.rect.midY)
                            .help("\(tile.folder.url.path) · \(ByteCountFormatter.string(fromByteCount: tile.folder.bytes, countStyle: .file))")
                        }
                    }
                }
                .frame(height: 230)
                .padding(.horizontal, 12)

                Table(folders) {
                    TableColumn("Folder") { folder in Text(folder.url.lastPathComponent).help(folder.url.path) }
                    TableColumn("Size") { folder in Text(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file)) }
                    TableColumn("Files") { folder in Text("\(folder.files)") }
                    TableColumn("Share") { folder in
                        let percent = total == 0 ? 0 : Double(folder.bytes) * 100 / Double(total)
                        Text(String(format: "%.1f%%", percent))
                    }
                }
                .padding(.horizontal, 8)
                .overlay { if folders.isEmpty { ContentUnavailableView("No Files", systemImage: "externaldrive") } }
            }
            HStack {
                Text("Counts regular files under each immediate child; symbolic links are not followed.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(minWidth: 680, minHeight: 420)
        .task { scan() }
    }

    private func scan() {
        Task.detached(priority: .userInitiated) {
            do {
                let result = try Self.measure(root)
                await MainActor.run { folders = result; isScanning = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isScanning = false }
            }
        }
    }

    nonisolated private static func measure(_ root: URL) throws -> [Folder] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
        var stats: [String: (bytes: Int64, files: Int)] = [:]
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { continue }
            stats[child.path] = values.isDirectory == true ? (0, 0) : (Int64(values.fileSize ?? 0), 1)
        }
        // Match the visible Retron folder scan: hidden items and package
        // contents contribute to their parent directory's disk usage.
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: []) else { return [] }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isDirectory != true else { continue }
            if url.deletingLastPathComponent() == root { continue }
            var ancestor = url.deletingLastPathComponent()
            while ancestor.deletingLastPathComponent() != root && ancestor != root { ancestor.deleteLastPathComponent() }
            guard var value = stats[ancestor.path] else { continue }
            value.bytes += Int64(values.fileSize ?? 0)
            value.files += 1
            stats[ancestor.path] = value
        }
        return stats.map { path, value in Folder(url: URL(fileURLWithPath: path), bytes: value.bytes, files: value.files) }
        .sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private static func layout(_ folders: [Folder], in size: CGSize) -> [Tile] {
        let nonempty = folders.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard !nonempty.isEmpty, size.width > 0, size.height > 0 else { return [] }
        func partition(_ items: ArraySlice<Folder>, _ rect: CGRect) -> [Tile] {
            guard !items.isEmpty else { return [] }
            if items.count == 1, let item = items.first { return [Tile(folder: item, rect: rect)] }
            let values = Array(items)
            let total = values.reduce(Int64(0)) { $0 + $1.bytes }
            var cumulative: Int64 = 0
            var split = 1
            for index in 0..<(values.count - 1) {
                cumulative += values[index].bytes
                split = index + 1
                if cumulative * 2 >= total { break }
            }
            let leftTotal = values.prefix(split).reduce(Int64(0)) { $0 + $1.bytes }
            let fraction = total == 0 ? 0.5 : CGFloat(leftTotal) / CGFloat(total)
            if rect.width >= rect.height {
                let width = rect.width * fraction
                return partition(values[..<split][...], CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)) +
                    partition(values[split...][...], CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
            } else {
                let height = rect.height * fraction
                return partition(values[..<split][...], CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)) +
                    partition(values[split...][...], CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
            }
        }
        return partition(nonempty[...], CGRect(origin: .zero, size: size))
    }
}
