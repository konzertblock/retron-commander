import Darwin
import Foundation

enum BatchRenameFileList {
    static func enumerate(selected: [URL], mask: String, includeSubdirectories: Bool) -> [URL] {
        var files: [URL] = []
        for item in selected {
            var itemStat = stat()
            let isSymbolicLink = lstat(item.path, &itemStat) == 0 && (itemStat.st_mode & S_IFMT) == S_IFLNK
            let isDirectory = !isSymbolicLink && ((try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            if includeSubdirectories && isDirectory {
                guard let enumerator = FileManager.default.enumerator(
                    at: item,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                ) else { continue }
                for case let url as URL in enumerator {
                    var childStat = stat()
                    let childIsSymbolicLink = lstat(url.path, &childStat) == 0 && (childStat.st_mode & S_IFMT) == S_IFLNK
                    let childIsDirectory = !childIsSymbolicLink && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                    if !childIsDirectory && FileTransferService.matchesFile(url.lastPathComponent, mask: mask) {
                        files.append(url)
                    }
                }
            } else if FileTransferService.matchesFile(item.lastPathComponent, mask: mask) {
                files.append(item)
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
