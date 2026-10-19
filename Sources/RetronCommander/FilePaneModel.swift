import AppKit
import Combine
import Darwin
import Foundation

struct FileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let byteSize: Int64
    let modifiedAt: Date?
    let attributes: String
    let isParent: Bool
    var calculatedDirectorySize: Int64? = nil
    var archivePath: String? = nil
    var archiveURL: URL? = nil

    var id: String { archivePath.map { "archive:\(archiveURL?.standardizedFileURL.path ?? url.standardizedFileURL.path)#\($0)" } ?? url.standardizedFileURL.path }
    var extensionName: String { isDirectory ? "" : url.pathExtension }
    var displaySize: String {
        if isDirectory {
            return calculatedDirectorySize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "<DIR>"
        }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool {
        lhs.id == rhs.id && lhs.calculatedDirectorySize == rhs.calculatedDirectorySize
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class FilePaneModel: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var entries: [FileEntry] = []
    @Published var selectedIDs: Set<String> = []
    @Published var focusedID: String?
    @Published var errorMessage: String?
    @Published var showsHiddenFiles = false
    @Published private(set) var archiveURL: URL?
    @Published private(set) var archiveDirectory = ""
    var displayPath: String { archiveURL.map { "\($0.path)\\\(archiveDirectory)" } ?? directory.path }
    private var sortColumn = "name"
    private var sortAscending = true
    private var shortcutSortColumn: String?
    private var selectionMemory: Set<String> = []
    private var reloadGeneration = 0

    private struct Location: Equatable {
        let directory: URL
        let archiveURL: URL?
        let archiveDirectory: String
    }
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var location: Location { Location(directory: directory, archiveURL: archiveURL, archiveDirectory: archiveDirectory) }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory
    }

    var selectedEntries: [FileEntry] {
        let chosen = entries.filter { selectedIDs.contains($0.id) }
        if !chosen.isEmpty { return chosen }
        return entries.filter { $0.id == focusedID }
    }

    func selectAll() { selectedIDs = Set(entries.filter { !$0.isParent }.map(\.id)) }
    func unselectAll() { selectedIDs.removeAll() }
    func storeSelection() {
        selectionMemory = Set(entries.filter { selectedIDs.contains($0.id) && !$0.isParent }.map(\.name))
    }
    func restoreSelection() {
        selectedIDs = Set(entries.filter { !$0.isParent && selectionMemory.contains($0.name) }.map(\.id))
    }
    func invertSelection() {
        selectedIDs = Set(entries.filter { !$0.isParent && !selectedIDs.contains($0.id) }.map(\.id))
    }

    func sortBy(column: String, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        sortEntries()
    }

    func toggleShortcutSort(column: String) {
        if shortcutSortColumn == column {
            sortAscending.toggle()
        } else {
            shortcutSortColumn = column
            sortColumn = column
            sortAscending = true
        }
        sortColumn = column
        sortEntries()
    }

    func calculateDirectorySizes() {
        guard archiveURL == nil else { return }
        let folders = entries.filter { $0.isDirectory && !$0.isParent }.map(\.url)
        guard !folders.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                let sizes = try await Task.detached(priority: .userInitiated) {
                    try DirectorySizeCalculator.logicalSizesByRoot(folders)
                }.value
                guard let self else { return }
                entries = entries.map { entry in
                    var updated = entry
                    updated.calculatedDirectorySize = sizes[entry.url.standardizedFileURL.path]
                    return updated
                }
                if sortColumn == "size" { sortEntries() }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func applyMask(_ mask: String, selecting: Bool) {
        let sections = mask.components(separatedBy: "|")
        let included = Self.splitMasks(sections.first ?? "*")
        let excluded = sections.count > 1 ? Self.splitMasks(sections.dropFirst().joined(separator: "|")) : []
        let matches: Set<String> = Set(entries.filter { entry in
            guard !entry.isParent else { return false }
            let include = included.isEmpty || included.contains { Self.matches(entry.name, pattern: $0) }
            let exclude = excluded.contains { Self.matches(entry.name, pattern: $0) }
            return include && !exclude
        }.map(\.id))
        if selecting { selectedIDs.formUnion(matches) } else { selectedIDs.subtract(matches) }
    }

    private static func splitMasks(_ value: String) -> [String] {
        var result: [String] = []
        var token = ""
        let chars = Array(value)
        var index = 0
        while index < chars.count {
            if chars[index] == ";" {
                if index + 1 < chars.count && chars[index + 1] == ";" { token.append(";"); index += 1 }
                else { if !token.isEmpty { result.append(token) }; token = "" }
            } else { token.append(chars[index]) }
            index += 1
        }
        if !token.isEmpty { result.append(token) }
        return result
    }

    private static func matches(_ name: String, pattern: String) -> Bool {
        let pattern = pattern == "*.*" ? "*" : pattern
        var expression = "^"
        for character in pattern {
            switch character {
            case "*": expression += ".*"
            case "?": expression += "."
            default: expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        expression += "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    func navigate(to url: URL, remember: Bool = true) {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "The folder does not exist: \(target.path)"
            return
        }
        if remember, location != Location(directory: target, archiveURL: nil, archiveDirectory: "") {
            backStack.append(location)
            forwardStack.removeAll()
        }
        directory = target
        archiveURL = nil
        archiveDirectory = ""
        selectedIDs.removeAll()
        errorMessage = nil
        reload()
    }

    func navigate(toPath path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    func parent() {
        if archiveURL != nil {
            navigateArchive(to: archiveDirectory.isEmpty ? nil : String(archiveDirectory.split(separator: "/").dropLast().joined(separator: "/")))
            return
        }
        let target = directory.deletingLastPathComponent()
        if target != directory { navigate(to: target) }
    }

    func back() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(location)
        restore(target)
    }

    func forward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(location)
        restore(target)
    }

    private func restore(_ target: Location) {
        directory = target.directory
        archiveURL = target.archiveURL
        archiveDirectory = target.archiveDirectory
        selectedIDs.removeAll()
        errorMessage = nil
        reload()
    }

    func enterArchive(_ archive: URL) {
        do {
            _ = try ArchiveService.list(archive)
            backStack.append(location)
            forwardStack.removeAll()
            archiveURL = archive
            archiveDirectory = ""
            selectedIDs.removeAll()
            errorMessage = nil
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func navigateArchive(to path: String?) {
        guard let archiveURL else { return }
        backStack.append(location)
        forwardStack.removeAll()
        if let path { archiveDirectory = path }
        else {
            self.archiveURL = nil
            archiveDirectory = ""
            selectedIDs = [archiveURL.standardizedFileURL.path]
            directory = archiveURL.deletingLastPathComponent()
        }
        reload()
    }

    func extractSelection(to destination: URL) throws {
        guard let archiveURL else { throw ArchiveError.invalidArchive }
        let chosen = selectedEntries.compactMap { entry -> ArchiveService.Item? in
            guard let path = entry.archivePath else { return nil }
            return ArchiveService.Item(path: path, size: entry.byteSize, packedSize: 0, modified: "", isDirectory: entry.isDirectory)
        }
        guard !chosen.isEmpty else { throw ArchiveError.noSelection }
        try ArchiveService.extract(chosen, from: archiveURL, to: destination)
    }

    func reload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        if let archiveURL {
            let archiveDirectory = self.archiveDirectory
            let containingDirectory = directory
            Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> ([FileEntry], String?) in
                    do {
                        let all = try ArchiveService.list(archiveURL)
                        let prefix = archiveDirectory.isEmpty ? "" : archiveDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                        var children: [String: FileEntry] = [:]
                        for item in all {
                            let path = item.path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            guard path.hasPrefix(prefix) else { continue }
                            let remainder = String(path.dropFirst(prefix.count))
                            guard !remainder.isEmpty else { continue }
                            let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
                            guard let first = components.first else { continue }
                            let name = String(first)
                            let childPath = prefix + name
                            let isDirectory = components.count > 1 || item.isDirectory
                            let url = archiveURL.appendingPathComponent(childPath)
                            let entry = FileEntry(url: url, name: name, isDirectory: isDirectory, byteSize: components.count == 1 ? item.size : 0, modifiedAt: nil, attributes: "", isParent: false, archivePath: childPath, archiveURL: archiveURL)
                            if let current = children[name], current.isDirectory { continue }
                            children[name] = entry
                        }
                        return (Array(children.values), nil)
                    } catch { return ([], error.localizedDescription) }
                }.value
                guard let self, self.reloadGeneration == generation else { return }
                if let error = result.1 {
                    self.entries = []
                    self.errorMessage = error
                    return
                }
                self.entries = result.0
                self.sortEntries()
                let parentURL = archiveDirectory.isEmpty ? containingDirectory.appendingPathComponent("..") : archiveURL
                self.entries.insert(FileEntry(url: parentURL, name: "..", isDirectory: true, byteSize: 0, modifiedAt: nil, attributes: "", isParent: true), at: 0)
                self.selectedIDs = self.selectedIDs.intersection(Set(self.entries.map(\.id)))
            }
            return
        }
        let directory = self.directory
        let showsHiddenFiles = self.showsHiddenFiles
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([FileEntry], String?) in
                do {
                    guard let directoryHandle = opendir(directory.path) else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    defer { closedir(directoryHandle) }
                    var loaded: [FileEntry] = []
                    while let item = readdir(directoryHandle) {
                        let nameLength = Int(item.pointee.d_namlen)
                        let name = withUnsafePointer(to: item.pointee.d_name) { namePointer in
                            namePointer.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) { String(cString: $0) }
                        }
                        guard name != ".", name != ".." else { continue }
                        let url = directory.appendingPathComponent(name)
                        var info = stat()
                        guard url.path.withCString({ lstat($0, &info) }) == 0 else { continue }
                        let hidden = url.lastPathComponent.hasPrefix(".") || (info.st_flags & UInt32(truncatingIfNeeded: UF_HIDDEN) != 0)
                        guard showsHiddenFiles || !hidden else { continue }
                        let isDirectory = (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                        var attributeMarkers = ""
                        if hidden { attributeMarkers += "H" }
                        if (info.st_mode & 0o222) == 0 { attributeMarkers += "R" }
                        if (info.st_flags & UInt32(truncatingIfNeeded: UF_IMMUTABLE)) != 0 { attributeMarkers += "L" }
                        let modifiedAt = Date(
                            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                        )
                        loaded.append(FileEntry(
                            url: url,
                            name: url.lastPathComponent,
                            isDirectory: isDirectory,
                            byteSize: Int64(info.st_size),
                            modifiedAt: modifiedAt,
                            attributes: attributeMarkers,
                            isParent: false
                        ))
                    }
                    return (loaded, nil)
                } catch { return ([], error.localizedDescription) }
            }.value
            guard let self, self.reloadGeneration == generation else { return }
            if let error = result.1 {
                self.entries = []
                self.errorMessage = error
                return
            }
            self.entries = result.0
            self.errorMessage = nil
            self.sortEntries()
            if directory.deletingLastPathComponent() != directory {
                let up = directory.deletingLastPathComponent()
                self.entries.insert(FileEntry(url: up, name: "..", isDirectory: true, byteSize: 0, modifiedAt: nil, attributes: "", isParent: true), at: 0)
            }
            self.selectedIDs = self.selectedIDs.intersection(Set(self.entries.map(\.id)))
            if let focusedID = self.focusedID, !self.entries.contains(where: { $0.id == focusedID }) { self.focusedID = nil }
        }
    }

    private func sortEntries() {
        entries.sort { left, right in
            if left.isParent != right.isParent { return left.isParent }
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let order: ComparisonResult
            switch sortColumn {
            case "ext": order = left.extensionName.localizedStandardCompare(right.extensionName)
            case "size":
                let leftSize = left.calculatedDirectorySize ?? left.byteSize
                let rightSize = right.calculatedDirectorySize ?? right.byteSize
                order = leftSize == rightSize ? .orderedSame : (leftSize < rightSize ? .orderedAscending : .orderedDescending)
            case "date":
                guard let leftDate = left.modifiedAt, let rightDate = right.modifiedAt else {
                    order = left.modifiedAt == nil ? (right.modifiedAt == nil ? .orderedSame : .orderedAscending) : .orderedDescending
                    break
                }
                order = leftDate == rightDate ? .orderedSame : (leftDate < rightDate ? .orderedAscending : .orderedDescending)
            case "attributes": order = left.attributes.localizedStandardCompare(right.attributes)
            default: order = left.name.localizedStandardCompare(right.name)
            }
            if order == .orderedSame { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    func open(_ entry: FileEntry) {
        if entry.isParent { parent() }
        else if let archivePath = entry.archivePath, entry.isDirectory { navigateArchive(to: archivePath) }
        else if entry.archivePath == nil, !entry.isDirectory, ArchiveService.isSupportedArchive(entry.url) { enterArchive(entry.url) }
        else if entry.isDirectory { navigate(to: entry.url) }
        else { NSWorkspace.shared.open(entry.url) }
    }

    func renameSelection(to newName: String) throws {
        guard selectedEntries.count == 1, let entry = selectedEntries.first else { return }
        if archiveURL != nil {
            try rename([entry], to: [newName])
            return
        }
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: entry.url, to: target)
        selectedIDs = [target.path]
        reload()
    }

    func rename(_ entries: [FileEntry], to names: [String]) throws {
        try rename(entries, to: names, root: directory, pathMode: .fileName)
    }

    func rename(_ entries: [FileEntry], to names: [String], root: URL, pathMode: BatchRenameTemplate.PathMode, removeEmptiedDirectories: Bool = false) throws {
        guard entries.count == names.count else { return }
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let archiveURL {
            guard pathMode == .fileName, cleaned.allSatisfy({ !$0.contains("/") }) else { throw BatchRenameFileService.Failure.invalidName }
            guard entries.allSatisfy({ $0.archiveURL == archiveURL && $0.archivePath != nil }) else {
                throw ArchiveError.mixedArchiveSelections
            }
            let selections = entries.compactMap { entry -> ArchiveService.Item? in
                guard let path = entry.archivePath else { return nil }
                return ArchiveService.Item(path: path, size: entry.byteSize, packedSize: 0, modified: "", isDirectory: entry.isDirectory)
            }
            let renamedPaths = try ArchiveService.rename(selections, to: cleaned, in: archiveURL)
            reload()
            selectedIDs = Set(renamedPaths.map { "archive:\(archiveURL.standardizedFileURL.path)#\($0)" })
            return
        }
        let targets = try BatchRenameFileService.rename(entries.map { .init(url: $0.url, isDirectory: $0.isDirectory) }, to: cleaned, root: root, pathMode: pathMode)
        if removeEmptiedDirectories {
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            var parents = Set<URL>()
            for entry in entries {
                var parent = entry.url.deletingLastPathComponent().standardizedFileURL
                while parent.path != rootPath && parent.path.hasPrefix(prefix) {
                    parents.insert(parent)
                    let next = parent.deletingLastPathComponent().standardizedFileURL
                    if next == parent { break }
                    parent = next
                }
            }
            let orderedParents = parents.sorted { $0.path.count > $1.path.count }
            for directory in orderedParents where FileManager.default.fileExists(atPath: directory.path) {
                if let children = try? FileManager.default.contentsOfDirectory(atPath: directory.path), children.isEmpty {
                    try FileManager.default.removeItem(at: directory)
                }
            }
        }
        selectedIDs = Set(targets.map(\.path))
        reload()
    }

    func createDirectory(named name: String) throws {
        let target = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        reload()
        selectedIDs = [target.path]
    }

    func deleteSelection() throws {
        if let archiveURL {
            let items = selectedEntries.compactMap { entry -> ArchiveService.Item? in
                guard let path = entry.archivePath else { return nil }
                return ArchiveService.Item(path: path, size: entry.byteSize, packedSize: 0, modified: "", isDirectory: entry.isDirectory)
            }
            guard !items.isEmpty else { throw ArchiveError.noSelection }
            try ArchiveService.remove(items, from: archiveURL)
            selectedIDs.removeAll()
            reload()
            return
        }
        for entry in selectedEntries where !entry.isParent {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resultingURL)
        }
        selectedIDs.removeAll()
        reload()
    }

    typealias CollisionBehavior = TransferCollisionBehavior

    func transferSelection(to destination: URL, move: Bool, collisions: CollisionBehavior = .fail) throws {
        let items = selectedEntries.filter { !$0.isParent }
        let completed = try FileTransferService.transfer(sources: items.map(\.url), to: destination, move: move, collisions: collisions)
        selectedIDs.subtract(Set(completed))
        reload()
    }
}

private enum FileOperationError: LocalizedError {
    case invalidName
    case duplicateDestination
    case destinationExists(String)
    var errorDescription: String? {
        switch self {
        case .invalidName: "A new name is empty or contains an invalid path separator."
        case .duplicateDestination: "Two files would have the same new name."
        case .destinationExists(let name): "The destination already exists: \(name)"
        }
    }
}
