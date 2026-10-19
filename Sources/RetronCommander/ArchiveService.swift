import Foundation

enum ArchiveService {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case zip, sevenZip = "7z", tar, gzip, bzip2, xz, zstd, pak
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .zip: "ZIP"
            case .sevenZip: "7-Zip"
            case .tar: "TAR"
            case .gzip: "GZip"
            case .bzip2: "BZip2"
            case .xz: "XZ"
            case .zstd: "Zstandard"
            case .pak: "Quake PAK"
            }
        }
        var fileExtension: String { rawValue }
        var archiveType: String { rawValue }
    }

    struct Item: Identifiable, Hashable, Sendable {
        let path: String
        let size: Int64
        let packedSize: Int64
        let modified: String
        let isDirectory: Bool
        var id: String { path }
    }

    static let supportedExtensions: Set<String> = [
        "7z", "zip", "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz",
        "zst", "tzst", "rar", "arj", "cab", "lha", "lzh", "iso", "udf", "ima",
        "chm", "rpm", "deb", "cpio", "pak", "wim", "swm", "esd"
    ]

    static func isSupportedArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.range(of: #"\.(7z|zip)\.\d{3}$"#, options: .regularExpression) != nil { return true }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func list(_ archive: URL, password: String? = nil, controller: TransferController? = nil) throws -> [Item] {
        if archive.pathExtension.lowercased() == "ima" {
            let image = try DiskImageService(image: archive)
            return try image.listAll().map { item in
                Item(
                    path: item.path,
                    size: Int64(item.size),
                    packedSize: 0,
                    modified: item.modified?.formatted(date: .numeric, time: .shortened) ?? "",
                    isDirectory: item.isDirectory
                )
            }
        }
        if archive.pathExtension.lowercased() == "pak" { return try PAKArchiveService.list(archive) }
        guard let tool = sevenZipURL else { throw ArchiveError.missingTool }
        let arguments = ["l"] + (password.map { ["-p\($0)"] } ?? []) + ["-slt", "--", archive.path]
        let output = try run(tool, arguments: arguments, controller: controller)
        var records: [[String: String]] = []
        var record: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty {
                if let path = record["Path"], path != archive.path {
                    records.append(record)
                }
                record = [:]
            } else if let separator = line.range(of: " = ") {
                record[String(line[..<separator.lowerBound])] = String(line[separator.upperBound...])
            }
        }
        if let path = record["Path"], path != archive.path { records.append(record) }
        guard output.contains("Type = ") else { throw ArchiveError.invalidArchive }
        return records.compactMap { record in
            guard let rawPath = record["Path"], let path = safeArchivePath(rawPath) else { return nil }
            let folder = record["Folder"] == "+" || rawPath.hasSuffix("/") || rawPath.hasSuffix("\\")
            return Item(
                path: path,
                size: Int64(record["Size"] ?? "") ?? 0,
                packedSize: Int64(record["Packed Size"] ?? "") ?? 0,
                modified: record["Modified"] ?? "",
                isDirectory: folder
            )
        }
    }

    private static func safeArchivePath(_ rawPath: String) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
              normalized.range(of: "^[A-Za-z]:", options: .regularExpression) == nil else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return components.map(String.init).joined(separator: "/")
    }

    static func extract(_ items: [Item], from archive: URL, to destination: URL, password: String? = nil, controller: TransferController? = nil) throws {
        if archive.pathExtension.lowercased() == "ima" {
            let image = try DiskImageService(image: archive)
            do {
                try image.extract(paths: Set(items.map(\.path)), to: destination) { completed, total, path in
                    if let controller {
                        if controller.snapshot.totalBytes != total { controller.setTotalBytes(total) }
                        return controller.reportProgress(
                            fileName: path.isEmpty ? archive.lastPathComponent : path,
                            copiedBytes: completed
                        )
                    }
                    return true
                }
            } catch DiskImageService.ImageError.cancelled {
                throw FileTransferError.cancelled
            }
            return
        }
        if archive.pathExtension.lowercased() == "pak" {
            controller?.setTotalBytes(items.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) })
            try PAKArchiveService.extract(items, from: archive, to: destination, controller: controller)
            return
        }
        guard let tool = sevenZipURL else { throw ArchiveError.missingTool }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = items.map(\.path)
        let args = ["x", "-y"] + (password.map { ["-p\($0)"] } ?? []) + ["-o\(destination.path)", "--", archive.path] + names
        _ = try run(tool, arguments: args, controller: controller)
    }

    static func extractAll(from archive: URL, to destination: URL, password: String? = nil, controller: TransferController? = nil) throws {
        try extract(try list(archive, password: password, controller: controller), from: archive, to: destination, password: password, controller: controller)
    }

    @discardableResult
    static func test(_ archive: URL, password: String? = nil) throws -> String {
        if archive.pathExtension.lowercased() == "ima" {
            _ = try list(archive)
            return "Disk image contents are readable."
        }
        if archive.pathExtension.lowercased() == "pak" {
            try PAKArchiveService.test(archive)
            return "PAK structure and all member data are readable."
        }
        guard let tool = sevenZipURL else { throw ArchiveError.missingTool }
        let arguments = ["t"] + (password.map { ["-p\($0)"] } ?? []) + ["--", archive.path]
        return try run(tool, arguments: arguments)
    }

    static func remove(_ chosen: [Item], from archive: URL) throws {
        if archive.pathExtension.lowercased() == "ima" { throw ArchiveError.readOnlyImage }
        let allItems = try list(archive)
        let pathsToRemove = Set(chosen.flatMap { selected in
            allItems.filter { item in
                item.path == selected.path || (selected.isDirectory && item.path.hasPrefix(selected.path + "/"))
            }.map(\.path)
        })
        try removeExact(paths: pathsToRemove, from: archive)
    }

    static func removeExact(_ chosen: [Item], from archive: URL) throws {
        if archive.pathExtension.lowercased() == "ima" { throw ArchiveError.readOnlyImage }
        try removeExact(paths: Set(chosen.map(\.path)), from: archive)
    }

    static func rename(_ selections: [Item], to names: [String], in archive: URL) throws -> [String] {
        if archive.pathExtension.lowercased() == "ima" { throw ArchiveError.readOnlyImage }
        guard selections.count == names.count, !selections.isEmpty else { return [] }
        let allItems = try list(archive)
        let normalizedNames = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalizedNames.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != "." && $0 != ".." }) else {
            throw ArchiveError.invalidName
        }
        let newRoots = zip(selections, normalizedNames).map { selection, name -> (Item, String) in
            let parent = selection.path.split(separator: "/").dropLast().joined(separator: "/")
            return (selection, parent.isEmpty ? name : "\(parent)/\(name)")
        }
        var replacements: [String: String] = [:]
        for item in allItems {
            guard let (selection, newRoot) = newRoots.first(where: { selection, _ in
                item.path == selection.path || (selection.isDirectory && item.path.hasPrefix(selection.path + "/"))
            }) else { continue }
            let suffix = String(item.path.dropFirst(selection.path.count))
            let newPath = newRoot + suffix
            guard safeArchivePath(newPath) == newPath else { throw ArchiveError.invalidName }
            if item.path != newPath { replacements[item.path] = newPath }
        }
        guard Set(allItems.map { replacements[$0.path] ?? $0.path }.map { $0.lowercased() }).count == allItems.count else {
            throw ArchiveError.duplicateArchivePath
        }
        guard !replacements.isEmpty else { return newRoots.map(\.1) }
        if archive.pathExtension.lowercased() == "pak" {
            try PAKArchiveService.rename(paths: replacements, from: archive)
        } else {
            guard let tool = sevenZipURL else { throw ArchiveError.missingTool }
            let arguments = replacements.keys.sorted().flatMap { [$0, replacements[$0]!] }
            _ = try run(tool, arguments: ["rn", "--", archive.path] + arguments)
        }
        return newRoots.map(\.1)
    }

    private static func removeExact(paths pathsToRemove: Set<String>, from archive: URL) throws {
        if archive.pathExtension.lowercased() == "ima" { throw ArchiveError.readOnlyImage }
        guard !pathsToRemove.isEmpty else { return }
        if archive.pathExtension.lowercased() == "pak" {
            try PAKArchiveService.remove(paths: pathsToRemove, from: archive)
            return
        }
        guard let tool = sevenZipURL else { throw ArchiveError.missingTool }
        _ = try run(tool, arguments: ["d", "-y", "--", archive.path] + pathsToRemove.sorted())
    }

    private static var sevenZipURL: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("7zz"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let candidates = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func run(_ executable: URL, arguments: [String], currentDirectory: URL? = nil, controller: TransferController? = nil) throws -> String {
        guard controller?.waitUntilResumed() != false else { throw ArchiveError.cancelled }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        controller?.attachProcess(process)
        defer { controller?.detachProcess(process) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if controller?.snapshot.cancelled == true { throw ArchiveError.cancelled }
            throw ArchiveError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "7-Zip exited with status \(process.terminationStatus)." : text)
        }
        return text
    }

    static func pack(_ entries: [FileEntry], in directory: URL) throws -> URL {
        try pack(entries, in: directory, format: .zip, compressionLevel: 5)
    }

    static func pack(_ entries: [FileEntry], in directory: URL, format: Format, compressionLevel: Int) throws -> URL {
        let items = entries.filter { !$0.isParent }
        guard !items.isEmpty else { throw ArchiveError.noSelection }

        let baseName = items.count == 1 ? items[0].name : "Selected Items"
        let archive = directory.appendingPathComponent(baseName + "." + format.fileExtension)
        return try pack(items, to: archive, format: format, compressionLevel: compressionLevel)
    }

    static func pack(_ entries: [FileEntry], to archive: URL, format: Format, compressionLevel: Int, password: String? = nil, volumeSizeMegabytes: Int? = nil) throws -> URL {
        let items = entries.filter { !$0.isParent }
        guard !items.isEmpty else { throw ArchiveError.noSelection }
        if let sourceArchive = items.first?.archiveURL {
            guard items.allSatisfy({ $0.archiveURL == sourceArchive && $0.archivePath != nil }) else {
                throw ArchiveError.mixedArchiveSelections
            }
            let selections = items.compactMap { entry -> Item? in
                guard let path = entry.archivePath else { return nil }
                return Item(path: path, size: entry.byteSize, packedSize: 0, modified: "", isDirectory: entry.isDirectory)
            }
            let archiveItems = try list(sourceArchive)
            let included = archiveItems.filter { item in
                selections.contains { selected in
                    item.path == selected.path || (selected.isDirectory && item.path.hasPrefix(selected.path + "/"))
                }
            }
            guard !included.isEmpty else { throw ArchiveError.noSelection }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("retron-archive-pack-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try extract(included, from: sourceArchive, to: temporary)
            let materialized = items.compactMap { entry -> FileEntry? in
                guard let path = entry.archivePath else { return nil }
                return FileEntry(
                    url: temporary.appendingPathComponent(path),
                    name: entry.name,
                    isDirectory: entry.isDirectory,
                    byteSize: entry.byteSize,
                    modifiedAt: entry.modifiedAt,
                    attributes: entry.attributes,
                    isParent: false
                )
            }
            return try pack(materialized, to: archive, format: format, compressionLevel: compressionLevel, password: password, volumeSizeMegabytes: volumeSizeMegabytes)
        }
        if format == .pak {
            guard password == nil else { throw ArchiveError.encryptionUnsupported(format.displayName) }
            try PAKArchiveService.pack(items, to: archive)
            return archive
        }
        if let password {
            guard format == .zip || format == .sevenZip else { throw ArchiveError.encryptionUnsupported(format.displayName) }
            guard !password.isEmpty else { throw ArchiveError.emptyPassword }
        }
        if let volumeSizeMegabytes {
            guard format == .sevenZip, (1...1_000_000).contains(volumeSizeMegabytes) else {
                throw ArchiveError.invalidVolumeSize
            }
        }
        guard (0...9).contains(compressionLevel) else { throw ArchiveError.invalidCompressionLevel }
        let firstVolume = URL(fileURLWithPath: archive.path + ".001")
        guard !FileManager.default.fileExists(atPath: archive.path),
              !FileManager.default.fileExists(atPath: firstVolume.path) else {
            throw ArchiveError.destinationExists(archive.lastPathComponent)
        }

        guard let tool = sevenZipURL else { throw ArchiveError.missingTool }
        var arguments = ["a", "-t\(format.archiveType)", "-mx=\(compressionLevel)", "-y"]
        if let password {
            arguments.append("-p\(password)")
            arguments.append(format == .zip ? "-mem=AES256" : "-mhe=on")
        }
        if let volumeSizeMegabytes { arguments.append("-v\(volumeSizeMegabytes)m") }
        arguments += ["--", archive.path] + items.map(\.name)
        do {
            _ = try run(tool, arguments: arguments, currentDirectory: items[0].url.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: archive)
            removeVolumeParts(for: archive)
            throw error
        }
        return volumeSizeMegabytes == nil ? archive : firstVolume
    }

    private static func removeVolumeParts(for archive: URL) {
        let directory = archive.deletingLastPathComponent()
        let prefix = archive.lastPathComponent + "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.dropFirst(prefix.count).count == 3 && name.dropFirst(prefix.count).allSatisfy(\.isNumber) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func unpack(_ entries: [FileEntry]) throws -> [URL] {
        let archives = entries.filter { !$0.isParent && isSupportedArchive($0.url) }
        guard !archives.isEmpty else { throw ArchiveError.noArchiveSelected }
        var extracted: [URL] = []

        for archive in archives {
            let destination = archive.url.deletingLastPathComponent()
                .appendingPathComponent(archive.url.deletingPathExtension().lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ArchiveError.destinationExists(destination.lastPathComponent)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

            do {
                try extractAll(from: archive.url, to: destination)
                extracted.append(destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        return extracted
    }
}

enum ArchiveError: LocalizedError {
    case noSelection
    case noArchiveSelected
    case missingTool
    case invalidArchive
    case destinationExists(String)
    case commandFailed(String)
    case invalidCompressionLevel
    case mixedArchiveSelections
    case duplicateArchivePath
    case invalidName
    case emptyPassword
    case encryptionUnsupported(String)
    case cancelled
    case readOnlyImage
    case invalidVolumeSize

    var errorDescription: String? {
        switch self {
        case .noSelection: "Select at least one item to archive."
        case .noArchiveSelected: "Select one or more supported archives to unpack."
        case .missingTool: "7-Zip is required for archive browsing and extraction. Install 7-Zip or 7zz, then retry."
        case .invalidArchive: "The file is not a valid archive or its listing could not be read."
        case .destinationExists(let name): "The destination already exists: \(name)"
        case .commandFailed(let detail): detail
        case .invalidCompressionLevel: "Compression level must be between 0 and 9."
        case .mixedArchiveSelections: "Archive selections must all come from the same open archive."
        case .duplicateArchivePath: "The rename would create duplicate archive paths."
        case .invalidName: "An archive entry name is empty or contains an invalid path component."
        case .emptyPassword: "Enter a password to encrypt the archive."
        case .encryptionUnsupported(let format): "Password encryption is not supported for \(format) archives."
        case .cancelled: "Archive operation cancelled."
        case .readOnlyImage: "FAT disk images are read-only. Copy items out of the image instead of moving or deleting them."
        case .invalidVolumeSize: "Choose a volume size from 1 MB to 1,000,000 MB. Volume splitting is available for 7-Zip archives."
        }
    }
}
