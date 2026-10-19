import Foundation

enum FileAttributeFilter: String, CaseIterable, Sendable {
    case any
    case present
    case absent

    func matches(_ value: Bool) -> Bool {
        switch self {
        case .any: true
        case .present: value
        case .absent: !value
        }
    }
}

struct FileTransferCriteria: Sendable {
    let minimumSize: Int64?
    let maximumSize: Int64?
    let modifiedAfter: Date?
    let modifiedBefore: Date?
    let hidden: FileAttributeFilter
    let readOnly: FileAttributeFilter
    let locked: FileAttributeFilter

    var isEmpty: Bool {
        minimumSize == nil && maximumSize == nil && modifiedAfter == nil && modifiedBefore == nil
            && hidden == .any && readOnly == .any && locked == .any
    }

    func includesFile(at url: URL) -> Bool {
        guard !isEmpty else { return true }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isHiddenKey, .isWritableKey]) else {
            return false
        }
        if let minimumSize, Int64(values.fileSize ?? -1) < minimumSize { return false }
        if let maximumSize, Int64(values.fileSize ?? Int.max) > maximumSize { return false }
        if let modifiedAfter, (values.contentModificationDate ?? .distantPast) < modifiedAfter { return false }
        if let modifiedBefore, (values.contentModificationDate ?? .distantFuture) > modifiedBefore { return false }
        let isHidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
        if !hidden.matches(isHidden) { return false }
        if !readOnly.matches(values.isWritable == false) { return false }
        let isLocked = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.immutable] as? NSNumber)?.boolValue ?? false
        if !locked.matches(isLocked) { return false }
        return true
    }
}
