import Foundation

final class DiskImageService: @unchecked Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let name: String
        let path: String
        let size: UInt32
        let isDirectory: Bool
        let attributes: UInt8
        let modified: Date?
        var id: String { path }
    }

    enum ImageError: LocalizedError {
        case unreadable, unsupportedFileSystem, invalidPath, cancelled
        case mountFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The disk image could not be read."
            case .unsupportedFileSystem: "macOS could not mount a supported file system from this image."
            case .invalidPath: "The image path is invalid."
            case .cancelled: "Extraction was cancelled."
            case .mountFailed(let detail): detail
            }
        }
    }

    private let mountPoint: URL
    private let fileManager = FileManager.default

    init(image: URL) throws {
        guard fileManager.isReadableFile(atPath: image.path),
              let size = try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { throw ImageError.unreadable }

        let point = fileManager.temporaryDirectory
            .appendingPathComponent("RetronCommander-image-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: point, withIntermediateDirectories: true)
        do {
            try Self.runDiskutil(arguments: [
                "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", point.path, image.path
            ])
        } catch {
            try? fileManager.removeItem(at: point)
            throw error
        }
        mountPoint = point
        guard fileManager.fileExists(atPath: point.path) else {
            try? Self.runHdiutil(arguments: ["detach", "-force", point.path])
            try? fileManager.removeItem(at: point)
            throw ImageError.unsupportedFileSystem
        }
    }

    deinit {
        try? Self.runHdiutil(arguments: ["detach", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    var filesystemName: String { "Mounted disk image" }

    func list(path: String = "") throws -> [Entry] {
        let directory = try resolve(path)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isWritableKey
            ], options: [])
        } catch {
            throw ImageError.mountFailed(error.localizedDescription)
        }

        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isWritableKey
            ])
            guard values.isSymbolicLink != true else { return nil }
            let isDirectory = values.isDirectory == true
            let relative = path.isEmpty ? url.lastPathComponent : "\(path)/\(url.lastPathComponent)"
            var attributes: UInt8 = url.lastPathComponent.hasPrefix(".") ? 0x02 : 0
            if values.isWritable == false { attributes |= 0x01 }
            return Entry(
                name: url.lastPathComponent,
                path: relative,
                size: UInt32(clamping: values.fileSize ?? 0),
                isDirectory: isDirectory,
                attributes: attributes,
                modified: values.contentModificationDate
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func listAll() throws -> [Entry] {
        var entries: [Entry] = []
        var visited = Set<String>()
        func walk(_ relativePath: String) throws {
            let directory = try resolve(relativePath)
            guard visited.insert(directory.standardizedFileURL.path).inserted else { return }
            for entry in try list(path: relativePath) {
                entries.append(entry)
                if entry.isDirectory { try walk(entry.path) }
            }
        }
        try walk("")
        return entries
    }

    func extract(
        _ entries: [Entry],
        to destination: URL,
        progress: @Sendable (_ completedBytes: Int64, _ totalBytes: Int64, _ currentPath: String) -> Bool = { _, _, _ in true }
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let roots = entries.filter { item in
            !entries.contains(where: { parent in
                parent.isDirectory && item.path != parent.path && item.path.hasPrefix(parent.path + "/")
            })
        }
        let totalBytes = try roots.reduce(Int64(0)) { $0 + (try byteCount(of: $1)) }
        var completed: Int64 = 0
        guard progress(0, totalBytes, "") else { throw ImageError.cancelled }
        for entry in roots {
            try copy(entry, to: destination, completed: &completed, total: totalBytes, progress: progress)
        }
    }

    func extract(
        paths: Set<String>,
        to destination: URL,
        progress: @Sendable (Int64, Int64, String) -> Bool = { _, _, _ in true }
    ) throws {
        guard !paths.isEmpty else { return }
        let all = Dictionary(uniqueKeysWithValues: try listAll().map { ($0.path, $0) })
        let selected = try paths.sorted().map { path -> Entry in
            guard let item = all[path] else { throw ImageError.invalidPath }
            return item
        }
        try extract(selected, to: destination, progress: progress)
    }

    private func byteCount(of entry: Entry) throws -> Int64 {
        guard entry.isDirectory else { return Int64(entry.size) }
        return try list(path: entry.path).reduce(Int64(0)) { $0 + (try byteCount(of: $1)) }
    }

    private func copy(
        _ entry: Entry,
        to destination: URL,
        completed: inout Int64,
        total: Int64,
        progress: @Sendable (Int64, Int64, String) -> Bool
    ) throws {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw ImageError.invalidPath }
        let source = try resolve(entry.path)
        let output = components.reduce(destination) { $0.appendingPathComponent(String($1), isDirectory: entry.isDirectory) }
        if entry.isDirectory {
            try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            for child in try list(path: entry.path) {
                try copy(child, to: destination, completed: &completed, total: total, progress: progress)
            }
            return
        }

        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).extract-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            let target = try FileHandle(forWritingTo: temporary)
            defer { try? input.close(); try? target.close() }
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try target.write(contentsOf: chunk)
                let (next, overflow) = completed.addingReportingOverflow(Int64(chunk.count))
                guard !overflow, progress(next, total, entry.path) else { throw ImageError.cancelled }
                completed = next
            }
            try target.close()
            try input.close()
            if fileManager.fileExists(atPath: output.path) {
                _ = try fileManager.replaceItemAt(output, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: output)
            }
            if let date = entry.modified { try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: output.path) }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func resolve(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw ImageError.invalidPath }
        let url = components.reduce(mountPoint) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        let root = mountPoint.standardizedFileURL.path
        guard url.path == root || url.path.hasPrefix(root + "/") else { throw ImageError.invalidPath }
        return url
    }

    private static func runDiskutil(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw ImageError.mountFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImageError.mountFailed(message?.isEmpty == false ? message! : "macOS could not mount this disk image.")
        }
    }
    private static func runHdiutil(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        do { try process.run() }
        catch { throw ImageError.mountFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImageError.mountFailed(message?.isEmpty == false ? message! : "The disk image could not be detached.")
        }
    }

}
