import Foundation

enum BatchRenameFileService {
    struct Item {
        let url: URL
        let isDirectory: Bool
    }

    enum Failure: LocalizedError {
        case invalidName
        case duplicateDestination
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: "The new name or path is invalid."
            case .duplicateDestination: "More than one item would have the same destination."
            case .destinationExists(let name): "An item named \(name) already exists at the destination."
            }
        }
    }

    @discardableResult
    static func rename(_ items: [Item], to names: [String], root: URL, pathMode: BatchRenameTemplate.PathMode) throws -> [URL] {
        guard items.count == names.count else { return [] }
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cleaned.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.invalidName }

        let rootPath = root.standardizedFileURL.path
        let targets = try zip(items, cleaned).map { item, name -> URL in
            switch pathMode {
            case .fileName:
                guard !name.contains("/") else { throw Failure.invalidName }
                return item.url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
            case .relativePath:
                guard !name.hasPrefix("/") else { throw Failure.invalidName }
                let target = root.appendingPathComponent(name).standardizedFileURL
                let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard target.path.hasPrefix(rootPrefix) else { throw Failure.invalidName }
                return target
            case .fullPath:
                guard name.hasPrefix("/") else { throw Failure.invalidName }
                return URL(fileURLWithPath: name).standardizedFileURL
            }
        }
        guard Set(targets.map(\.path)).count == targets.count else { throw Failure.duplicateDestination }

        let sourcePaths = Set(items.map { $0.url.standardizedFileURL.path })
        for (item, target) in zip(items, targets) {
            if target.path == item.url.standardizedFileURL.path { continue }
            if FileManager.default.fileExists(atPath: target.path) && !sourcePaths.contains(target.path) {
                throw Failure.destinationExists(target.lastPathComponent)
            }
            if item.isDirectory && target.path.hasPrefix(item.url.standardizedFileURL.path + "/") { throw Failure.invalidName }
        }

        let changes = zip(items, targets).filter { $0.0.url.standardizedFileURL.path != $0.1.path }
        var staged: [(original: URL, temporary: URL, destination: URL)] = []
        do {
            for (item, target) in changes {
                let temporary = item.url.deletingLastPathComponent().appendingPathComponent(".retron-rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: item.url, to: temporary)
                staged.append((item.url, temporary, target))
            }
            for item in staged {
                try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.temporary, to: item.destination)
            }
        } catch {
            for item in staged.reversed()
                where FileManager.default.fileExists(atPath: item.destination.path) && !FileManager.default.fileExists(atPath: item.temporary.path) {
                try? FileManager.default.moveItem(at: item.destination, to: item.temporary)
            }
            for item in staged.reversed() {
                if FileManager.default.fileExists(atPath: item.temporary.path) {
                    try? FileManager.default.moveItem(at: item.temporary, to: item.original)
                }
            }
            throw error
        }
        return targets
    }
}
