import Foundation
import Darwin
import RetronCopyFile

final class TransferController: Identifiable, @unchecked Sendable {
    struct Snapshot: Sendable {
        let paused: Bool
        let cancelled: Bool
        let bytesCopied: Int64
        let totalBytes: Int64
        let speedLimit: Int64?
        let currentName: String
        let operationName: String
        let backendRunning: Bool
        let backendPaused: Bool
    }

    let id = UUID()
    let operationName: String
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var copied: Int64 = 0
    private var fileBase: Int64 = 0
    private var total: Int64
    private var speedLimit: Int64?
    private var startedAt = Date()
    private var pauseStartedAt: Date?
    private var lastUpdate = Date.distantPast
    private var currentName = ""
    private var activeProcess: Process?
    private var activeProcessIsSuspended = false
    private let onUpdate: (@Sendable (Snapshot) -> Void)?

    init(totalBytes: Int64, onUpdate: (@Sendable (Snapshot) -> Void)? = nil) {
        operationName = "Transfer"
        total = max(0, totalBytes)
        self.onUpdate = onUpdate
    }

    init(totalBytes: Int64, operationName: String, onUpdate: (@Sendable (Snapshot) -> Void)? = nil) {
        self.operationName = operationName
        total = max(0, totalBytes)
        self.onUpdate = onUpdate
    }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return Snapshot(paused: paused, cancelled: cancelled, bytesCopied: copied, totalBytes: total,
                        speedLimit: speedLimit, currentName: currentName, operationName: operationName,
                        backendRunning: activeProcess?.isRunning == true, backendPaused: activeProcessIsSuspended)
    }

    func setPaused(_ value: Bool) {
        condition.lock()
        if value && !paused { pauseStartedAt = Date() }
        if !value, paused {
            if let pauseStartedAt { startedAt.addTimeInterval(Date().timeIntervalSince(pauseStartedAt)) }
            pauseStartedAt = nil
        }
        paused = value
        if let process = activeProcess, process.isRunning {
            if value && !activeProcessIsSuspended {
                process.suspend()
                activeProcessIsSuspended = true
            } else if !value && activeProcessIsSuspended {
                process.resume()
                activeProcessIsSuspended = false
            }
        }
        if !value { condition.broadcast() }
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func setSpeedLimit(_ bytesPerSecond: Int64?) {
        condition.lock()
        speedLimit = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        condition.broadcast()
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func setTotalBytes(_ totalBytes: Int64) {
        condition.lock()
        total = max(0, totalBytes)
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func resetProgress(totalBytes: Int64) {
        condition.lock()
        copied = 0
        fileBase = 0
        total = max(0, totalBytes)
        startedAt = Date()
        lastUpdate = .distantPast
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func setCurrentName(_ name: String) {
        condition.lock()
        currentName = name
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func cancel() {
        condition.lock()
        cancelled = true
        if let process = activeProcess, process.isRunning {
            if activeProcessIsSuspended {
                process.resume()
                activeProcessIsSuspended = false
            }
            process.terminate()
        }
        condition.broadcast()
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    fileprivate func progress(source: UnsafePointer<CChar>?, copiedBytes: Int64) -> Bool {
        condition.lock()
        copied = max(copied, fileBase + copiedBytes)
        if let source { currentName = URL(fileURLWithPath: String(cString: source)).lastPathComponent }
        while paused && !cancelled { condition.wait() }
        if cancelled {
            condition.unlock()
            return false
        }
        if speedLimit != nil {
            while !cancelled {
                guard let currentLimit = speedLimit, currentLimit > 0 else { break }
                let elapsed = Date().timeIntervalSince(startedAt)
                let expected = Double(copied) / Double(currentLimit)
                let remaining = expected - elapsed
                if remaining <= 0 { break }
                _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.25)))
                while paused && !cancelled { condition.wait() }
            }
        }
        let now = Date()
        let shouldPublish = now.timeIntervalSince(lastUpdate) >= 0.15
        if shouldPublish { lastUpdate = now }
        let value = shouldPublish ? makeSnapshot() : nil
        condition.unlock()
        if let value { onUpdate?(value) }
        return true
    }

    fileprivate func finishFile(_ file: URL, copiedBytes: Int64) {
        condition.lock()
        copied = fileBase + max(0, copiedBytes)
        fileBase = copied
        currentName = file.lastPathComponent
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    fileprivate func beginFile(_ file: URL) {
        condition.lock()
        fileBase = copied
        currentName = file.lastPathComponent
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func waitUntilResumed() -> Bool {
        condition.lock()
        while paused && !cancelled { condition.wait() }
        let shouldContinue = !cancelled
        condition.unlock()
        return shouldContinue
    }

    func reportProgress(fileName: String, copiedBytes: Int64) -> Bool {
        condition.lock()
        copied = max(copied, copiedBytes)
        currentName = URL(fileURLWithPath: fileName).lastPathComponent
        while paused && !cancelled { condition.wait() }
        if cancelled {
            condition.unlock()
            return false
        }
        if speedLimit != nil {
            while !cancelled {
                guard let currentLimit = speedLimit, currentLimit > 0 else { break }
                let elapsed = Date().timeIntervalSince(startedAt)
                let expected = Double(copied) / Double(currentLimit)
                let remaining = expected - elapsed
                if remaining <= 0 { break }
                _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.25)))
                while paused && !cancelled { condition.wait() }
            }
        }
        let now = Date()
        let shouldPublish = now.timeIntervalSince(lastUpdate) >= 0.15
        if shouldPublish { lastUpdate = now }
        let value = shouldPublish ? makeSnapshot() : nil
        condition.unlock()
        if let value { onUpdate?(value) }
        return true
    }

    func attachProcess(_ process: Process) {
        condition.lock()
        activeProcess = process
        if cancelled, process.isRunning {
            process.terminate()
        } else if paused, process.isRunning {
            process.suspend()
            activeProcessIsSuspended = true
        }
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    func detachProcess(_ process: Process) {
        condition.lock()
        if activeProcess === process {
            if activeProcessIsSuspended, process.isRunning { process.resume() }
            activeProcessIsSuspended = false
            activeProcess = nil
        }
        let value = makeSnapshot()
        condition.unlock()
        onUpdate?(value)
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(paused: paused, cancelled: cancelled, bytesCopied: copied, totalBytes: total,
                 speedLimit: speedLimit, currentName: currentName, operationName: operationName,
                 backendRunning: activeProcess?.isRunning == true, backendPaused: activeProcessIsSuspended)
    }
}

enum TransferCollisionBehavior: Equatable, Sendable {
    case fail
    case skip
    case keepBoth
    case overwrite
    case overwriteOlderSkipNewer
}

enum FileTransferService {
    static func totalSize(of sources: [URL], criteria: FileTransferCriteria? = nil) -> Int64 {
        var total: Int64 = 0
        for source in sources {
            var sourceStat = stat()
            guard lstat(source.path, &sourceStat) == 0 else { continue }
            if (sourceStat.st_mode & S_IFMT) == S_IFREG {
                guard criteria?.includesFile(at: source) ?? true else { continue }
                total += max(0, Int64(sourceStat.st_size))
            } else if (sourceStat.st_mode & S_IFMT) == S_IFDIR {
                guard let enumerator = FileManager.default.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: []
                ) else { continue }
                for case let item as URL in enumerator {
                    guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    guard criteria?.includesFile(at: item) ?? true else { continue }
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        return total
    }

    static func transfer(sources: [URL], to destination: URL, move: Bool, collisions: TransferCollisionBehavior, fileMask: String? = nil, onlyNonEmptyDirectories: Bool = false, preserveDirectoryDates: Bool = true, preservePermissions: Bool = true, preserveExtendedAttributes: Bool = true, operationMask: String? = nil, criteria: FileTransferCriteria? = nil, controller: TransferController? = nil) throws -> [String] {
        var completed: [String] = []
        for source in sources {
            let targetName = FileOperationMask.apply(operationMask, to: source.lastPathComponent)
            if try transfer(source, to: destination.appendingPathComponent(targetName), move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, criteria: criteria, controller: controller) {
                completed.append(source.path)
            }
        }
        return completed
    }

    private static func transfer(_ source: URL, to requestedTarget: URL, move: Bool, collisions: TransferCollisionBehavior, fileMask: String?, onlyNonEmptyDirectories: Bool, preserveDirectoryDates: Bool, preservePermissions: Bool, preserveExtendedAttributes: Bool, criteria: FileTransferCriteria?, controller: TransferController?) throws -> Bool {
        if let controller, !controller.waitUntilResumed() { throw FileTransferError.cancelled }
        guard source.standardizedFileURL.path != requestedTarget.standardizedFileURL.path else { return false }
        var target = requestedTarget
        var sourceStat = stat()
        let sourceLStatSucceeded = lstat(source.path, &sourceStat) == 0
        let sourceIsSymbolicLink = sourceLStatSucceeded && (sourceStat.st_mode & S_IFMT) == S_IFLNK
        var sourceIsDirectory: ObjCBool = false
        if !sourceIsSymbolicLink { _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) }
        if !sourceIsDirectory.boolValue, let criteria, !criteria.includesFile(at: source) { return false }
        var targetIsDirectory: ObjCBool = false
        if !sourceIsDirectory.boolValue, let fileMask, !matchesFile(source.lastPathComponent, mask: fileMask) { return false }
        var targetStat = stat()
        var targetExists = lstat(target.path, &targetStat) == 0
        if targetExists { targetIsDirectory = ObjCBool(targetStat.st_mode & S_IFMT == S_IFDIR) }
        let targetPreviouslyExisted = targetExists

        if targetExists && sourceIsDirectory.boolValue && targetIsDirectory.boolValue && collisions != .keepBoth {
            // Existing same-name directories are merged. Individual files below
            // are resolved using the selected conflict policy.
        } else if targetExists {
            switch collisions {
            case .fail: throw FileTransferError.destinationExists(target.lastPathComponent)
            case .skip: return false
            case .keepBoth: target = uniqueURL(for: source, isDirectory: sourceIsDirectory.boolValue, in: target.deletingLastPathComponent())
            case .overwrite: try FileManager.default.removeItem(at: target)
            case .overwriteOlderSkipNewer:
                let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let targetDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard sourceDate > targetDate else { return false }
                try FileManager.default.removeItem(at: target)
            }
            targetExists = false
        }

        if sourceIsDirectory.boolValue {
            if !targetExists {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                _ = try transfer(child, to: target.appendingPathComponent(child.lastPathComponent), move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, criteria: criteria, controller: controller)
            }
            if onlyNonEmptyDirectories, !targetPreviouslyExisted,
               (try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)).isEmpty {
                try FileManager.default.removeItem(at: target)
            } else if FileManager.default.fileExists(atPath: target.path) {
                try copyDirectoryMetadata(from: source, to: target,
                                          preserveDirectoryDates: preserveDirectoryDates,
                                          preservePermissions: preservePermissions,
                                          preserveExtendedAttributes: preserveExtendedAttributes)
            }
            if move {
                if onlyNonEmptyDirectories && !FileManager.default.fileExists(atPath: target.path) { return false }
                let remaining = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                if remaining.isEmpty { try FileManager.default.removeItem(at: source); return true }
                return false
            }
            return FileManager.default.fileExists(atPath: target.path)
        }

        if sourceIsSymbolicLink {
            if move {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: linkDestination)
            }
            return true
        }

        var destinationStat = stat()
        let sourceIsRegular = sourceLStatSucceeded && (sourceStat.st_mode & S_IFMT) == S_IFREG
        if sourceIsRegular {
            let totalBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            do {
                let sourceVolume = sourceStat.st_dev
                let destinationVolume = stat(target.deletingLastPathComponent().path, &destinationStat) == 0 ? destinationStat.st_dev : -1
                let canRename = move && sourceVolume == destinationVolume
                if canRename {
                    controller?.beginFile(source)
                    try FileManager.default.moveItem(at: source, to: target)
                    controller?.finishFile(source, copiedBytes: totalBytes)
                } else {
                    controller?.beginFile(source)
                    let context = controller.map { Unmanaged.passUnretained($0).toOpaque() }
                    let result = source.path.withCString { sourcePath in
                        target.path.withCString { targetPath in
                            retron_copy_file(sourcePath, targetPath, move ? 1 : 0,
                                                 preservePermissions ? 1 : 0, preserveExtendedAttributes ? 1 : 0,
                                                 transferCopyProgress, context)
                        }
                    }
                    if result != 0 {
                        let copyError = errno
                        let cancelled = (controller?.snapshot.cancelled ?? false) || copyError == ECANCELED
                        if copyError != EEXIST { try? FileManager.default.removeItem(at: target) }
                        if cancelled { throw FileTransferError.cancelled }
                        throw FileTransferError.copyFailed(source.lastPathComponent, String(cString: strerror(copyError)))
                    }
                    controller?.finishFile(source, copiedBytes: totalBytes)
                }
            } catch {
                if !(error is FileTransferError), !move { try? FileManager.default.removeItem(at: target) }
                throw error
            }
        } else if move { try FileManager.default.moveItem(at: source, to: target) }
        else { try FileManager.default.copyItem(at: source, to: target) }
        return true
    }

    private static func copyDirectoryMetadata(from source: URL, to destination: URL,
                                             preserveDirectoryDates: Bool,
                                             preservePermissions: Bool,
                                             preserveExtendedAttributes: Bool) throws {
        var flags: copyfile_flags_t = 0
        if preservePermissions { flags |= copyfile_flags_t(COPYFILE_SECURITY) }
        if preserveExtendedAttributes { flags |= copyfile_flags_t(COPYFILE_XATTR) }
        if flags != 0 && copyfile(source.path, destination.path, nil, flags) != 0 {
            throw FileTransferError.copyFailed(source.lastPathComponent, String(cString: strerror(errno)))
        }
        let date = preserveDirectoryDates
            ? ((try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
            : Date()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
    }

    static func matchesFile(_ name: String, mask: String) -> Bool {
        let groups = mask.components(separatedBy: "|")
        let included = splitMasks(groups.first ?? "*")
        let excluded = groups.dropFirst().flatMap(splitMasks)
        let isIncluded = included.isEmpty || included.contains { wildcard(name, pattern: $0) }
        return isIncluded && !excluded.contains { wildcard(name, pattern: $0) }
    }

    private static func splitMasks(_ value: String) -> [String] {
        var masks: [String] = []
        var current = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            if characters[index] == ";" {
                if index + 1 < characters.count && characters[index + 1] == ";" {
                    current.append(";")
                    index += 1
                } else {
                    if !current.isEmpty { masks.append(current) }
                    current = ""
                }
            } else {
                current.append(characters[index])
            }
            index += 1
        }
        if !current.isEmpty { masks.append(current) }
        return masks
    }

    private static func wildcard(_ name: String, pattern: String) -> Bool {
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

    private static func uniqueURL(for source: URL, isDirectory: Bool, in destination: URL) -> URL {
        let extensionName = source.pathExtension
        let stem = extensionName.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let suffix = " (\(number))"
            let name = extensionName.isEmpty ? stem + suffix : stem + suffix + "." + extensionName
            let candidate = destination.appendingPathComponent(name, isDirectory: isDirectory)
            var candidateStat = stat()
            if lstat(candidate.path, &candidateStat) != 0 { return candidate }
            number += 1
        }
    }
}

enum ArchiveTransferService {
    static func transfer(
        selections: [ArchiveService.Item],
        from archive: URL,
        to destination: URL,
        move: Bool,
        collisions: TransferCollisionBehavior,
        fileMask: String? = nil,
        onlyNonEmptyDirectories: Bool = false,
        preserveDirectoryDates: Bool = true,
        preservePermissions: Bool = true,
        preserveExtendedAttributes: Bool = true,
        operationMask: String? = nil,
        criteria: FileTransferCriteria? = nil,
        controller: TransferController? = nil
    ) throws -> [String] {
        if archive.pathExtension.lowercased() == "ima", move {
            throw ArchiveError.readOnlyImage
        }
        controller?.setCurrentName(archive.lastPathComponent)
        let archiveItems = try ArchiveService.list(archive, controller: controller)
        let included = archiveItems.filter { item in
            selections.contains { selection in
                item.path == selection.path || (selection.isDirectory && item.path.hasPrefix(selection.path + "/"))
            }
        }
        guard !included.isEmpty else { throw ArchiveError.noSelection }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("retron-archive-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        controller?.setCurrentName(archive.lastPathComponent)
        try ArchiveService.extract(included, from: archive, to: temporary, controller: controller)

        let extractedRoots = selections.map { temporary.appendingPathComponent($0.path) }
        controller?.resetProgress(totalBytes: FileTransferService.totalSize(of: extractedRoots, criteria: criteria))
        let transferred = try FileTransferService.transfer(
            sources: extractedRoots,
            to: destination,
            move: move,
            collisions: collisions,
            fileMask: fileMask,
            onlyNonEmptyDirectories: onlyNonEmptyDirectories,
            preserveDirectoryDates: preserveDirectoryDates,
            preservePermissions: preservePermissions,
            preserveExtendedAttributes: preserveExtendedAttributes,
            operationMask: operationMask,
            criteria: criteria,
            controller: controller
        )

        if move {
            let movedMembers = included.filter { item in
                !FileManager.default.fileExists(atPath: temporary.appendingPathComponent(item.path).path)
            }
            try ArchiveService.removeExact(movedMembers, from: archive)
        }

        let transferredSet = Set(transferred)
        return selections.compactMap { selection in
            let source = temporary.appendingPathComponent(selection.path)
            if move {
                if selection.isDirectory {
                    let members = included.filter { !$0.isDirectory && $0.path.hasPrefix(selection.path + "/") }
                    let directoryWasMoved = !FileManager.default.fileExists(atPath: source.path)
                    let membersWereMoved = members.allSatisfy { !FileManager.default.fileExists(atPath: temporary.appendingPathComponent($0.path).path) }
                    return directoryWasMoved && membersWereMoved ? selection.path : nil
                }
                return !FileManager.default.fileExists(atPath: source.path) ? selection.path : nil
            }
            return transferredSet.contains(source.path) ? selection.path : nil
        }
    }
}

actor FileTransferQueue {
    static let shared = FileTransferQueue()

    func enqueue(sources: [URL], to destination: URL, move: Bool, collisions: TransferCollisionBehavior, fileMask: String?, onlyNonEmptyDirectories: Bool, preserveDirectoryDates: Bool = true, preservePermissions: Bool = true, preserveExtendedAttributes: Bool = true, operationMask: String? = nil, criteria: FileTransferCriteria? = nil, controller: TransferController? = nil) throws -> [String] {
        try FileTransferService.transfer(sources: sources, to: destination, move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, operationMask: operationMask, criteria: criteria, controller: controller)
    }

    func enqueueArchive(selections: [ArchiveService.Item], from archive: URL, to destination: URL, move: Bool, collisions: TransferCollisionBehavior, fileMask: String?, onlyNonEmptyDirectories: Bool, preserveDirectoryDates: Bool = true, preservePermissions: Bool = true, preserveExtendedAttributes: Bool = true, operationMask: String? = nil, criteria: FileTransferCriteria? = nil, controller: TransferController? = nil) throws -> [String] {
        try ArchiveTransferService.transfer(selections: selections, from: archive, to: destination, move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, operationMask: operationMask, criteria: criteria, controller: controller)
    }
}

enum FileTransferError: LocalizedError {
    case destinationExists(String)
    case cancelled
    case copyFailed(String, String)
    var errorDescription: String? {
        switch self {
        case .destinationExists(let name): "The destination already exists: \(name)"
        case .cancelled: "Transfer cancelled."
        case .copyFailed(let name, let detail): "Could not copy \(name): \(detail)"
        }
    }
}

private func transferCopyProgress(_ copied: Int64, _ source: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 1 }
    let controller = Unmanaged<TransferController>.fromOpaque(context).takeUnretainedValue()
    return controller.progress(source: source, copiedBytes: copied) ? 1 : 0
}
