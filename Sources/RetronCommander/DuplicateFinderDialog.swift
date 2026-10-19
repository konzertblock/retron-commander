import CryptoKit
import SwiftUI

struct DuplicateFinderDialog: View {
    struct Duplicate: Identifiable, Sendable {
        let url: URL
        let size: Int64
        let digest: String
        let group: Int
        var id: String { url.path }
    }

    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var results: [Duplicate] = []
    @State private var isScanning = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Duplicate Files").font(.headline)
                    Text(root.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isScanning { ProgressView("Hashing files…") }
            }.padding(12)
            if let error {
                ContentUnavailableView("Scan Failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                Table(results) {
                    TableColumn("Group") { file in Text("\(file.group)") }.width(min: 45, ideal: 60)
                    TableColumn("File") { file in Text(file.url.path).lineLimit(1).help(file.url.path) }
                    TableColumn("Size") { file in Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) }.width(min: 80, ideal: 100)
                    TableColumn("SHA-256") { file in Text(file.digest).font(.system(size: 9, design: .monospaced)).lineLimit(1) }.width(min: 170, ideal: 220)
                }
                .overlay {
                    if !isScanning && results.isEmpty { ContentUnavailableView("No Duplicates Found", systemImage: "doc.on.doc") }
                }
            }
            HStack {
                Text(isScanning ? "Scanning recursively; symbolic links are skipped." : "\(results.count) duplicate copies found")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(minWidth: 780, minHeight: 440)
        .task { scan() }
    }

    private func scan() {
        Task.detached(priority: .userInitiated) {
            do {
                let files = try Self.find(root)
                await MainActor.run { results = files; isScanning = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isScanning = false }
            }
        }
    }

    nonisolated private static func find(_ root: URL) throws -> [Duplicate] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsPackageDescendants]) else { return [] }
        var candidates: [String: [(URL, Int64)]] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isDirectory != true else { continue }
            let size = Int64(values.fileSize ?? 0)
            candidates[String(size), default: []].append((url, size))
        }
        var groups: [[(URL, Int64, String)]] = []
        for sameSize in candidates.values where sameSize.count > 1 {
            var byHash: [String: [(URL, Int64)]] = [:]
            for (url, size) in sameSize {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                byHash[digest, default: []].append((url, size))
            }
            for (digest, matches) in byHash where matches.count > 1 {
                groups.append(matches.map { ($0.0, $0.1, digest) })
            }
        }
        var result: [Duplicate] = []
        for (groupIndex, files) in groups.enumerated() {
            for file in files {
                result.append(Duplicate(url: file.0, size: file.1, digest: file.2, group: groupIndex + 1))
            }
        }
        result.sort {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.url.path < $1.url.path
        }
        return result
    }
}
