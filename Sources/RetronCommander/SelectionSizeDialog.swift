import SwiftUI

struct SelectionSizeDialog: View {
    let roots: [URL]

    @Environment(\.dismiss) private var dismiss
    @State private var summary: DirectorySizeSummary?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calculate Space Occupied")
                .font(.headline)

            if let summary {
                LabeledContent("Files", value: summary.files.formatted())
                LabeledContent("Directories", value: summary.directories.formatted())
                LabeledContent("Logical size", value: ByteCountFormatter.string(fromByteCount: summary.logicalBytes, countStyle: .file))
                LabeledContent("Space occupied", value: ByteCountFormatter.string(fromByteCount: summary.allocatedBytes, countStyle: .file))
                if summary.unreadableItems > 0 {
                    Text("Could not read \(summary.unreadableItems) item(s).")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } else if let errorMessage {
                ContentUnavailableView("Could Not Calculate Size", systemImage: "externaldrive.badge.questionmark", description: Text(errorMessage))
            } else {
                ProgressView("Calculating selected items…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(summary == nil && errorMessage == nil)
            }
        }
        .padding(18)
        .frame(width: 380)
        .task {
            let worker = Task.detached(priority: .userInitiated) {
                try DirectorySizeCalculator.calculate(roots)
            }
            defer { worker.cancel() }
            do { summary = try await worker.value }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct DirectorySizeSummary: Sendable {
    var files: Int64 = 0
    var directories: Int64 = 0
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var unreadableItems: Int64 = 0
}

enum DirectorySizeCalculator {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
    ]

    static func calculate(_ roots: [URL]) throws -> DirectorySizeSummary {
        var result = DirectorySizeSummary()

        func accumulate(_ values: URLResourceValues) {
            if values.isDirectory == true && values.isSymbolicLink != true {
                result.directories += 1
            } else {
                result.files += 1
                let logical = Int64(values.fileSize ?? 0)
                result.logicalBytes += logical
                result.allocatedBytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }

        for root in roots {
            try Task.checkCancellation()
            do {
                let values = try root.resourceValues(forKeys: keys)
                accumulate(values)
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(keys),
                    options: [],
                    errorHandler: { _, _ in
                        result.unreadableItems += 1
                        return true
                    }
                ) else {
                    result.unreadableItems += 1
                    continue
                }
                while let child = enumerator.nextObject() as? URL {
                    try Task.checkCancellation()
                    do {
                        let childValues = try child.resourceValues(forKeys: keys)
                        accumulate(childValues)
                        if childValues.isSymbolicLink == true { enumerator.skipDescendants() }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result.unreadableItems += 1
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.unreadableItems += 1
            }
        }

        return result
    }

    static func logicalSizesByRoot(_ roots: [URL]) throws -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for root in roots {
            try Task.checkCancellation()
            sizes[root.standardizedFileURL.path] = try calculate([root]).logicalBytes
        }
        return sizes
    }
}
