import Foundation

enum CheckFailure: Error { case failed(String) }

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls = 0
    private var storedCompleted: Int64 = 0
    private var storedTotal: Int64 = 0
    private var storedPath = ""

    func record(completed: Int64, total: Int64, path: String) {
        lock.lock()
        storedCalls += 1
        storedCompleted = completed
        storedTotal = total
        storedPath = path
        lock.unlock()
    }

    var snapshot: (calls: Int, completed: Int64, total: Int64, path: String) {
        lock.lock()
        defer { lock.unlock() }
        return (storedCalls, storedCompleted, storedTotal, storedPath)
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

func setFAT12(_ value: UInt16, cluster: Int, in data: inout Data, fatOffset: Int) {
    let offset = cluster + cluster / 2
    let word = UInt16(data[fatOffset + offset]) | (UInt16(data[fatOffset + offset + 1]) << 8)
    let updated: UInt16
    if cluster & 1 == 0 {
        updated = (word & 0xF000) | (value & 0x0FFF)
    } else {
        updated = (word & 0x000F) | ((value & 0x0FFF) << 4)
    }
    data[fatOffset + offset] = UInt8(updated & 0xFF)
    data[fatOffset + offset + 1] = UInt8(updated >> 8)
}

func put16(_ value: UInt16, into data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8(value >> 8)
}

func put32(_ value: UInt32, into data: inout Data, at offset: Int) {
    for byte in 0..<4 { data[offset + byte] = UInt8((value >> (byte * 8)) & 0xFF) }
}

func makeFAT12Image(fileBytes: Data, at url: URL) throws {
    let sectorSize = 512
    let sectorCount = 2880
    let firstFAT = sectorSize
    let secondFAT = sectorSize * 10
    let root = sectorSize * 19
    let dataStart = sectorSize * 33
    let clustersNeeded = (fileBytes.count + sectorSize - 1) / sectorSize
    try require(clustersNeeded + 2 < sectorCount - 33, "Fixture does not fit on the FAT12 volume")

    var image = Data(repeating: 0, count: sectorSize * sectorCount)
    image[0] = 0xEB; image[1] = 0x3C; image[2] = 0x90
    image.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
    put16(512, into: &image, at: 11)
    image[13] = 1
    put16(1, into: &image, at: 14)
    image[16] = 2
    put16(224, into: &image, at: 17)
    put16(UInt16(sectorCount), into: &image, at: 19)
    image[21] = 0xF0
    put16(9, into: &image, at: 22)
    put16(18, into: &image, at: 24)
    put16(2, into: &image, at: 26)
    image[510] = 0x55; image[511] = 0xAA

    for fatOffset in [firstFAT, secondFAT] {
        setFAT12(0xFF0, cluster: 0, in: &image, fatOffset: fatOffset)
        setFAT12(0xFFF, cluster: 1, in: &image, fatOffset: fatOffset)
        for index in 0..<clustersNeeded {
            let cluster = index + 2
            let next = index + 1 == clustersNeeded ? 0xFFF : UInt16(cluster + 1)
            setFAT12(next, cluster: cluster, in: &image, fatOffset: fatOffset)
        }
    }

    let name = Array("BIGFILE BIN".utf8)
    image.replaceSubrange(root..<(root + 11), with: name)
    image[root + 11] = 0x20
    put16(2, into: &image, at: root + 26)
    put32(UInt32(fileBytes.count), into: &image, at: root + 28)

    for index in 0..<clustersNeeded {
        let sourceStart = index * sectorSize
        let sourceEnd = min(fileBytes.count, sourceStart + sectorSize)
        let targetStart = dataStart + index * sectorSize
        image.replaceSubrange(targetStart..<(targetStart + sourceEnd - sourceStart),
                              with: fileBytes[sourceStart..<sourceEnd])
    }
    try image.write(to: url, options: .atomic)
}

@main
struct VerifyDiskImageMounting {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retron-image-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = Data((0..<150_000).map { UInt8(($0 * 17 + 31) & 0xFF) })
        let imageURL = root.appendingPathComponent("stream.ima")
        try makeFAT12Image(fileBytes: source, at: imageURL)
        let service = try DiskImageService(image: imageURL)
        let entry = try service.list().first(where: { $0.name == "BIGFILE.BIN" })
        try require(entry != nil, "Large FAT12 fixture file was not listed")

        let successDestination = root.appendingPathComponent("success", isDirectory: true)
        try FileManager.default.createDirectory(at: successDestination, withIntermediateDirectories: true)
        try Data("old contents".utf8).write(to: successDestination.appendingPathComponent("BIGFILE.BIN"))
        let recorder = ProgressRecorder()
        try service.extract(paths: [entry!.path], to: successDestination) { completed, total, path in
            recorder.record(completed: completed, total: total, path: path)
            return true
        }
        let extracted = try Data(contentsOf: successDestination.appendingPathComponent("BIGFILE.BIN"))
        try require(extracted == source, "Streamed extraction did not preserve the complete byte sequence")
        let recorded = recorder.snapshot
        try require(recorded.calls >= 1, "Extraction did not report progress")
        try require(recorded.completed == Int64(source.count) && recorded.total == Int64(source.count), "Progress totals did not reach the file size")
        try require(recorded.path == entry!.path, "Progress did not identify the current archive member")

        let cancelDestination = root.appendingPathComponent("cancel", isDirectory: true)
        let cancelAfter = Int64(40_000)
        do {
            try service.extract([entry!], to: cancelDestination) { completed, _, _ in completed < cancelAfter }
            throw CheckFailure.failed("Cancellation was not reported")
        } catch DiskImageService.ImageError.cancelled {
            let remaining = try FileManager.default.contentsOfDirectory(atPath: cancelDestination.path)
            try require(remaining.isEmpty, "Cancelled extraction left a partial destination file")
        }

        let invalidURL = root.appendingPathComponent("invalid.ima")
        try Data("not a disk image".utf8).write(to: invalidURL)
        do {
            _ = try DiskImageService(image: invalidURL)
            throw CheckFailure.failed("An invalid image was mounted")
        } catch DiskImageService.ImageError.mountFailed {
            // Expected: hdiutil rejects malformed images.
        }

        print("Disk image mount verification passed: FAT12 browse/extract, progress, cancellation cleanup, invalid-image rejection")
    }
}

private let firstFATOffset = 512
private let secondFATOffset = 512 * 10
