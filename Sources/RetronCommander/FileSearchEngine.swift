import Foundation

struct FileSearchResult: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    var id: String { url.standardizedFileURL.path }
}

enum FileSearchEngine {
    static func search(
        root: URL,
        pattern: String,
        content: String,
        includeHidden: Bool
    ) throws -> [FileSearchResult] {
        let expression = try wildcardExpression(pattern.isEmpty ? "*" : pattern)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var results: [FileSearchResult] = []
        for case let url as URL in enumerator {
            if !includeHidden && url.lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard expression.firstMatch(in: url.lastPathComponent, range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)) != nil else { continue }
            if !content.isEmpty {
                guard values.isDirectory != true,
                      (try? contains(content, in: url)) == true else { continue }
            }
            results.append(FileSearchResult(
                url: url,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
        }
        return results.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    private static func wildcardExpression(_ pattern: String) throws -> NSRegularExpression {
        var escaped = NSRegularExpression.escapedPattern(for: pattern)
        escaped = escaped.replacingOccurrences(of: "\\*", with: ".*")
        escaped = escaped.replacingOccurrences(of: "\\?", with: ".")
        return try NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive])
    }

    private static func contains(_ needle: String, in url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Keep enough overlap for a case-folded search term to straddle two reads.
        let overlap = max(32, needle.utf8.count * 4 + 16)
        var carry = Data()
        var found = false
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            var window = carry
            window.append(chunk)
            let completeLength = completeUTF8PrefixLength(of: window)
            if completeLength > 0 {
                guard let text = String(data: window.prefix(completeLength), encoding: .utf8) else {
                    return false
                }
                if text.localizedCaseInsensitiveContains(needle) { found = true }
            }

            var carryStart = max(0, completeLength - overlap)
            while carryStart > 0 && window[carryStart] & 0b1100_0000 == 0b1000_0000 {
                carryStart -= 1
            }
            carry = Data(window[carryStart...])
        }

        guard let finalText = String(data: carry, encoding: .utf8) else { return false }
        return found || finalText.localizedCaseInsensitiveContains(needle)
    }

    private static func completeUTF8PrefixLength(of data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        var index = data.count - 1
        var continuationCount = 0
        while index > 0 && data[index] & 0b1100_0000 == 0b1000_0000 && continuationCount < 3 {
            continuationCount += 1
            index -= 1
        }
        let lead = data[index]
        let expectedLength: Int
        if lead & 0b1000_0000 == 0 { expectedLength = 1 }
        else if lead & 0b1110_0000 == 0b1100_0000 { expectedLength = 2 }
        else if lead & 0b1111_0000 == 0b1110_0000 { expectedLength = 3 }
        else if lead & 0b1111_1000 == 0b1111_0000 { expectedLength = 4 }
        else { return data.count }

        let trailingLength = data.count - index
        return trailingLength < expectedLength ? index : data.count
    }
}
