import Foundation

enum PagedFileService {
    static func size(of file: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func read(_ file: URL, at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw PagedFileError.invalidRange }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
}

private enum PagedFileError: LocalizedError {
    case invalidRange
    var errorDescription: String? { "The requested file offset or page size is invalid." }
}
