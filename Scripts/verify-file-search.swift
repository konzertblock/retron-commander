import Foundation

@main
enum VerifyFileSearch {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retron-file-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let largeFile = root.appendingPathComponent("large.txt")
        let boundary = 256 * 1024
        let target = "Needle-über-boundary"
        // Place the leading byte of “ü” at the end of the first read.
        var payload = Data(repeating: UInt8(ascii: "x"), count: boundary - 8)
        payload.append(Data(target.utf8))
        payload.append(Data(repeating: UInt8(ascii: "y"), count: 3 * 1024 * 1024))
        try payload.write(to: largeFile)

        let invalidText = root.appendingPathComponent("binary.txt")
        try Data([0xff, 0xfe] + Array("Needle-über-boundary".utf8)).write(to: invalidText)

        let found = try FileSearchEngine.search(root: root, pattern: "*.txt", content: "NEEDLE-ÜBER-BOUNDARY", includeHidden: false)
        precondition(found.map(\.url.lastPathComponent) == ["large.txt"], "large UTF-8 match across a read boundary was missed or invalid UTF-8 was treated as text")
        print("Streaming file-content search found a case-insensitive UTF-8 match across a 256 KiB boundary in a 3 MiB file and skipped invalid UTF-8")
    }
}
