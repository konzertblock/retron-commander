import Foundation

enum FileViewerSearchPattern: Sendable {
    case text(String, caseSensitive: Bool, wholeWords: Bool)
    case regularExpression(String, caseSensitive: Bool)
    case bytes([UInt8])
}

struct FileViewerSearchMatch: Sendable {
    let byteOffset: Int64
    let byteLength: Int64
}

enum FileViewerSearchService {
    private static let chunkSize = 512 * 1024

    static func find(
        in file: URL,
        fileSize: Int64,
        range: Range<Int64>,
        pattern: FileViewerSearchPattern,
        backwards: Bool
    ) throws -> FileViewerSearchMatch? {
        let lower = max(0, min(fileSize, range.lowerBound))
        let upper = max(lower, min(fileSize, range.upperBound))
        guard lower < upper else { return nil }
        let safeRange = lower..<upper

        switch pattern {
        case .text(let query, let caseSensitive, let wholeWords):
            guard !query.isEmpty else { return nil }
            return try findText(query, caseSensitive: caseSensitive, wholeWords: wholeWords,
                                in: file, fileSize: fileSize, range: safeRange, backwards: backwards)
        case .regularExpression(let source, let caseSensitive):
            return try findRegularExpression(source, caseSensitive: caseSensitive,
                                             in: file, range: safeRange, backwards: backwards)
        case .bytes(let needle):
            guard !needle.isEmpty else { return nil }
            return try findBytes(needle, in: file, range: safeRange, backwards: backwards)
        }
    }

    private static func findText(
        _ query: String,
        caseSensitive: Bool,
        wholeWords: Bool,
        in file: URL,
        fileSize: Int64,
        range: Range<Int64>,
        backwards: Bool
    ) throws -> FileViewerSearchMatch? {
        let overlap = max(64, query.utf8.count * 4 + 16)
        let step = max(chunkSize, overlap + 16)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        func matches(in text: String, byteBase: Int64, core: Range<Int64>) -> [FileViewerSearchMatch] {
            var found: [FileViewerSearchMatch] = []
            var searchFrom = text.startIndex
            while searchFrom < text.endIndex,
                  let match = text.range(of: query, options: options, range: searchFrom..<text.endIndex) {
                let prefixBytes = Int64(text[..<match.lowerBound].utf8.count)
                let matchOffset = byteBase + prefixBytes
                let matchLength = Int64(text[match.lowerBound..<match.upperBound].utf8.count)
                let matchEnd = matchOffset + matchLength
                if matchOffset >= core.lowerBound, matchOffset < core.upperBound,
                   matchEnd <= range.upperBound,
                   (!wholeWords || isWholeWord(match, in: text)) {
                    found.append(FileViewerSearchMatch(byteOffset: matchOffset, byteLength: matchLength))
                }
                searchFrom = match.upperBound > searchFrom ? match.upperBound : text.index(after: searchFrom)
            }
            return found
        }

        if backwards {
            var coreEnd = range.upperBound
            while coreEnd > range.lowerBound {
                try Task.checkCancellation()
                let coreStart = max(range.lowerBound, coreEnd - Int64(step))
                var readStart = max(0, coreStart - Int64(overlap))
                readStart = try alignedUTF8Start(in: handle, proposed: readStart)
                let readEnd = min(fileSize, coreEnd + Int64(overlap))
                let bytes = try read(handle, at: readStart, count: Int(readEnd - readStart))
                let completeLength = completeUTF8PrefixLength(of: bytes)
                let text = String(decoding: bytes.prefix(completeLength), as: UTF8.self)
                let candidates = matches(in: text, byteBase: readStart, core: coreStart..<coreEnd)
                if let match = candidates.last { return match }
                coreEnd = coreStart
            }
        } else {
            var coreStart = range.lowerBound
            while coreStart < range.upperBound {
                try Task.checkCancellation()
                let coreEnd = min(range.upperBound, coreStart + Int64(step))
                var readStart = max(0, coreStart - Int64(overlap))
                readStart = try alignedUTF8Start(in: handle, proposed: readStart)
                let readEnd = min(fileSize, coreEnd + Int64(overlap))
                let bytes = try read(handle, at: readStart, count: Int(readEnd - readStart))
                let completeLength = completeUTF8PrefixLength(of: bytes)
                let text = String(decoding: bytes.prefix(completeLength), as: UTF8.self)
                if let match = matches(in: text, byteBase: readStart, core: coreStart..<coreEnd).first {
                    return match
                }
                coreStart = coreEnd
            }
        }
        return nil
    }

    private static func findRegularExpression(
        _ source: String,
        caseSensitive: Bool,
        in file: URL,
        range: Range<Int64>,
        backwards: Bool
    ) throws -> FileViewerSearchMatch? {
        let expression = try NSRegularExpression(pattern: source, options: caseSensitive ? [] : [.caseInsensitive])
        let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
        let text = String(decoding: bytes, as: UTF8.self)
        let nsText = text as NSString
        let results = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let candidates = results.compactMap { result -> FileViewerSearchMatch? in
            guard let startIndex = Range(result.range, in: text)?.lowerBound,
                  let matchRange = Range(result.range, in: text) else { return nil }
            let offset = Int64(text[..<startIndex].utf8.count)
            guard offset >= range.lowerBound, offset < range.upperBound else { return nil }
            return FileViewerSearchMatch(byteOffset: offset, byteLength: Int64(text[matchRange].utf8.count))
        }
        return backwards ? candidates.last : candidates.first
    }

    private static func findBytes(
        _ needle: [UInt8],
        in file: URL,
        range: Range<Int64>,
        backwards: Bool
    ) throws -> FileViewerSearchMatch? {
        let overlapCount = needle.count - 1
        let step = max(chunkSize, needle.count)
        var position = range.lowerBound
        var carry: [UInt8] = []
        var lastMatch: FileViewerSearchMatch?
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        while position < range.upperBound {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(position))
            let count = Int(min(Int64(step), range.upperBound - position))
            let chunk = Array(try handle.read(upToCount: count) ?? Data())
            guard !chunk.isEmpty else { break }
            var window = carry
            window.append(contentsOf: chunk)
            let baseOffset = position - Int64(carry.count)
            if needle.count <= window.count {
                for start in 0...(window.count - needle.count) {
                    let absolute = baseOffset + Int64(start)
                    guard absolute >= range.lowerBound,
                          absolute + Int64(needle.count) <= range.upperBound else { continue }
                    if window[start..<(start + needle.count)].elementsEqual(needle) {
                        let match = FileViewerSearchMatch(byteOffset: absolute, byteLength: Int64(needle.count))
                        if !backwards { return match }
                        lastMatch = match
                    }
                }
            }
            carry = overlapCount == 0 ? [] : Array(window.suffix(min(overlapCount, window.count)))
            position += Int64(chunk.count)
        }
        return lastMatch
    }

    private static func isWholeWord(_ match: Range<String.Index>, in text: String) -> Bool {
        func isWord(_ index: String.Index) -> Bool {
            guard index < text.endIndex else { return false }
            return text[index].unicodeScalars.first.map {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
            } ?? false
        }
        let before = match.lowerBound > text.startIndex && isWord(text.index(before: match.lowerBound))
        let after = isWord(match.upperBound)
        return !before && !after
    }

    private static func alignedUTF8Start(in handle: FileHandle, proposed: Int64) throws -> Int64 {
        var result = proposed
        while result > 0 {
            let byte = try read(handle, at: result, count: 1).first ?? 0
            if byte & 0b1100_0000 != 0b1000_0000 { break }
            result -= 1
        }
        return result
    }

    private static func read(_ handle: FileHandle, at offset: Int64, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
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
