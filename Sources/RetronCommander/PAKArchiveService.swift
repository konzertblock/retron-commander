import Foundation

enum PAKArchiveService {
    private struct Entry {
        let path: String
        let offset: UInt32
        let size: UInt32
    }

    static func list(_ archive: URL) throws -> [ArchiveService.Item] {
        let entries = try readDirectory(archive)
        return entries.map {
            ArchiveService.Item(path: $0.path, size: Int64($0.size), packedSize: Int64($0.size), modified: "", isDirectory: false)
        }
    }

    static func test(_ archive: URL) throws {
        let entries = try readDirectory(archive)
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        for entry in entries {
            try file.seek(toOffset: UInt64(entry.offset))
            var remaining = UInt64(entry.size)
            while remaining > 0 {
                let data = try file.read(upToCount: min(Int(1024 * 1024), Int(remaining))) ?? Data()
                guard !data.isEmpty else { throw PAKError.truncated(entry.path) }
                remaining -= UInt64(data.count)
            }
        }
    }

    static func extract(_ items: [ArchiveService.Item], from archive: URL, to destination: URL, controller: TransferController? = nil) throws {
        let entries = try readDirectory(archive)
        let selected = Set(items.map(\.path))
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var totalCopied: Int64 = 0
        for entry in entries where selected.contains(entry.path) {
            guard controller?.waitUntilResumed() != false else { throw ArchiveError.cancelled }
            let relative = try safeRelativePath(entry.path)
            let outputURL = relative.reduce(destination) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.seek(toOffset: UInt64(entry.offset))
            let temporaryURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).pak-tmp")
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                let output = try FileHandle(forWritingTo: temporaryURL)
                defer { try? output.close() }
                var remaining = UInt64(entry.size)
                var fileCopied: Int64 = 0
                while remaining > 0 {
                    let chunk = try file.read(upToCount: min(64 * 1024, Int(remaining))) ?? Data()
                    guard !chunk.isEmpty else { throw PAKError.truncated(entry.path) }
                    try output.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                    fileCopied += Int64(chunk.count)
                    if let controller,
                       !controller.reportProgress(fileName: entry.path, copiedBytes: totalCopied + fileCopied) {
                        throw ArchiveError.cancelled
                    }
                }
                try output.synchronize()
                try output.close()
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                }
                totalCopied += fileCopied
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    static func remove(paths: Set<String>, from archive: URL) throws {
        let entries = try readDirectory(archive)
        let kept = entries.filter { !paths.contains($0.path) }
        guard kept.count != entries.count else { return }
        try rewrite(kept, from: archive)
    }

    static func rename(paths: [String: String], from archive: URL) throws {
        let entries = try readDirectory(archive)
        let renamed = try entries.map { entry -> Entry in
            let path = paths[entry.path] ?? entry.path
            guard Data(path.utf8).count <= 56 else { throw PAKError.pathTooLong(path) }
            _ = try safeRelativePath(path)
            return Entry(path: path, offset: entry.offset, size: entry.size)
        }
        guard Set(renamed.map(\.path)).count == renamed.count else { throw ArchiveError.duplicateArchivePath }
        guard zip(entries.map(\.path), renamed.map(\.path)).contains(where: { $0.0 != $0.1 }) else { return }
        try rewrite(renamed, from: archive)
    }

    private static func rewrite(_ entries: [Entry], from archive: URL) throws {
        let temporary = archive.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pak-tmp")
        let backup = archive.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pak-backup")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: backup)
        }
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data("PACK".utf8) + littleEndian(0) + littleEndian(0)) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: archive)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var rebuilt: [Entry] = []
        var offset: UInt64 = 12
        for entry in entries {
            guard offset <= UInt64(UInt32.max), offset + UInt64(entry.size) <= UInt64(UInt32.max) else {
                throw PAKError.archiveTooLarge
            }
            try output.seek(toOffset: offset)
            try input.seek(toOffset: UInt64(entry.offset))
            var remaining = UInt64(entry.size)
            while remaining > 0 {
                let data = try input.read(upToCount: min(Int(1024 * 1024), Int(remaining))) ?? Data()
                guard !data.isEmpty else { throw PAKError.truncated(entry.path) }
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
            }
            rebuilt.append(Entry(path: entry.path, offset: UInt32(offset), size: entry.size))
            offset += UInt64(entry.size)
        }

        let directoryOffset = offset
        for entry in rebuilt {
            var record = Data(entry.path.utf8)
            record.append(contentsOf: repeatElement(UInt8(0), count: 56 - record.count))
            record.append(littleEndian(entry.offset))
            record.append(littleEndian(entry.size))
            try output.seekToEnd()
            try output.write(contentsOf: record)
        }
        guard directoryOffset <= UInt64(UInt32.max), rebuilt.count * 64 <= Int(UInt32.max) else {
            throw PAKError.archiveTooLarge
        }
        try output.seek(toOffset: 4)
        try output.write(contentsOf: littleEndian(UInt32(directoryOffset)))
        try output.write(contentsOf: littleEndian(UInt32(rebuilt.count * 64)))
        try output.synchronize()
        try output.close()
        try input.close()

        try FileManager.default.moveItem(at: archive, to: backup)
        do {
            try FileManager.default.moveItem(at: temporary, to: archive)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: archive)
            throw error
        }
        try FileManager.default.removeItem(at: backup)
    }

    static func pack(_ entries: [FileEntry], to destination: URL) throws {
        let files = try collectFiles(entries)
        guard !files.isEmpty else { throw PAKError.emptySelection }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ArchiveError.destinationExists(destination.lastPathComponent)
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pak-tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path, contents: Data("PACK".utf8) + littleEndian(0) + littleEndian(0))
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var directory: [Entry] = []
        var offset: UInt64 = 12
        do {
            for (path, source) in files {
                let utf8 = Data(path.utf8)
                guard !utf8.isEmpty, utf8.count <= 56 else { throw PAKError.pathTooLong(path) }
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                guard offset <= UInt64(UInt32.max), size <= UInt64(UInt32.max), offset + size <= UInt64(UInt32.max) else {
                    throw PAKError.fileTooLarge(source.lastPathComponent)
                }
                try output.seek(toOffset: offset)
                try copyFile(source, to: output)
                directory.append(Entry(path: path, offset: UInt32(offset), size: UInt32(size)))
                offset += size
            }
            let directoryOffset = offset
            for entry in directory {
                var record = Data(entry.path.utf8)
                record.append(contentsOf: repeatElement(UInt8(0), count: 56 - record.count))
                record.append(littleEndian(entry.offset))
                record.append(littleEndian(entry.size))
                try output.seekToEnd()
                try output.write(contentsOf: record)
            }
            guard directoryOffset <= UInt64(UInt32.max), directory.count * 64 <= Int(UInt32.max) else { throw PAKError.archiveTooLarge }
            try output.seek(toOffset: 4)
            try output.write(contentsOf: littleEndian(UInt32(directoryOffset)))
            try output.write(contentsOf: littleEndian(UInt32(directory.count * 64)))
            try output.synchronize()
            try output.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw error
        }
    }

    private static func collectFiles(_ selections: [FileEntry]) throws -> [(String, URL)] {
        var byPath: [String: URL] = [:]
        let manager = FileManager.default
        for selection in selections where !selection.isParent {
            if selection.isDirectory {
                guard let enumerator = manager.enumerator(at: selection.url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in enumerator {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    guard values.isRegularFile == true else { continue }
                    let relative = String(file.path.dropFirst(selection.url.deletingLastPathComponent().path.count + 1))
                    byPath[relative.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "/")] = file
                }
            } else {
                byPath[selection.name.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "/")] = selection.url
            }
        }
        return try byPath.keys.sorted().map { path in
            _ = try safeRelativePath(path)
            return (path, byPath[path]!)
        }
    }

    private static func readDirectory(_ archive: URL) throws -> [Entry] {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        let totalSize = try file.seekToEnd()
        guard totalSize >= 12 else { throw PAKError.invalidHeader }
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("PACK".utf8) else { throw PAKError.invalidHeader }
        let directoryOffset = UInt64(readUInt32(header, at: 4))
        let directorySize = UInt64(readUInt32(header, at: 8))
        guard directorySize % 64 == 0, directoryOffset >= 12, directoryOffset <= totalSize,
              directorySize <= totalSize - directoryOffset else { throw PAKError.invalidDirectory }
        try file.seek(toOffset: directoryOffset)
        let data = try file.read(upToCount: Int(directorySize)) ?? Data()
        guard data.count == Int(directorySize) else { throw PAKError.invalidDirectory }
        var result: [Entry] = []
        for cursor in stride(from: 0, to: data.count, by: 64) {
            let nameData = data[cursor..<(cursor + 56)].prefix { $0 != 0 }
            guard !nameData.isEmpty else { continue }
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            let path = name.replacingOccurrences(of: "\\", with: "/")
            _ = try safeRelativePath(path)
            let offset = readUInt32(data, at: cursor + 56)
            let size = readUInt32(data, at: cursor + 60)
            guard UInt64(offset) >= 12, UInt64(offset) <= directoryOffset, UInt64(size) <= directoryOffset - UInt64(offset) else {
                throw PAKError.invalidEntry(path)
            }
            result.append(Entry(path: path, offset: offset, size: size))
        }
        return result
    }

    private static func safeRelativePath(_ path: String) throws -> [String] {
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !components.isEmpty, !path.hasPrefix("/"), components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw PAKError.unsafePath(path)
        }
        return components
    }

    private static func copyFile(_ source: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while true {
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
}

private enum PAKError: LocalizedError {
    case emptySelection, invalidHeader, invalidDirectory, archiveTooLarge
    case pathTooLong(String), fileTooLarge(String), invalidEntry(String), truncated(String), unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one regular file to add to the PAK archive."
        case .invalidHeader: "This file does not have a valid Quake PAK header."
        case .invalidDirectory: "The Quake PAK directory is invalid or truncated."
        case .archiveTooLarge: "The resulting Quake PAK exceeds its 32-bit format limits."
        case .pathTooLong(let path): "The PAK format limits each path to 56 UTF-8 bytes: \(path)"
        case .fileTooLarge(let name): "The PAK format cannot store this file: \(name)"
        case .invalidEntry(let path): "Invalid PAK entry bounds: \(path)"
        case .truncated(let path): "The PAK entry is truncated: \(path)"
        case .unsafePath(let path): "Refusing to extract an unsafe path: \(path)"
        }
    }
}
