import Foundation

struct DirectoryCompareEntry: Identifiable {
    enum Result: String {
        case same = "Same"
        case leftOnly = "Left only"
        case rightOnly = "Right only"
        case different = "Different"
    }

    let name: String
    let left: URL?
    let right: URL?
    let isDirectory: Bool
    let leftSize: Int64?
    let rightSize: Int64?
    let result: Result
    var id: String { name.lowercased() }
}

enum DirectoryCompareEngine {
    static func compare(left: URL, right: URL) throws -> [DirectoryCompareEntry] {
        let leftItems = try entries(in: left)
        let rightItems = try entries(in: right)
        let leftMap = Dictionary(leftItems.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let rightMap = Dictionary(rightItems.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(leftMap.keys).union(rightMap.keys).sorted()

        return names.compactMap { key in
            let l = leftMap[key]
            let r = rightMap[key]
            if let l, let r {
                let lv = try? l.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let rv = try? r.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let ld = lv?.isDirectory ?? false
                let rd = rv?.isDirectory ?? false
                let ls = Int64(lv?.fileSize ?? 0)
                let rs = Int64(rv?.fileSize ?? 0)
                let same = ld == rd && (ld || ls == rs)
                return DirectoryCompareEntry(name: l.lastPathComponent, left: l, right: r, isDirectory: ld || rd,
                                              leftSize: ld ? nil : ls, rightSize: rd ? nil : rs, result: same ? .same : .different)
            }
            let item = l ?? r!
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = isDirectory ? nil : Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return DirectoryCompareEntry(name: item.lastPathComponent, left: l, right: r, isDirectory: isDirectory,
                                          leftSize: l == nil ? nil : size, rightSize: r == nil ? nil : size,
                                          result: l == nil ? .rightOnly : .leftOnly)
        }
    }

    private static func entries(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
    }
}
