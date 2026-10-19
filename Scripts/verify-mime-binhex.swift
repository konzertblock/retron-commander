import Foundation
import Darwin

@main
enum VerifyMIMEBinHex {
    static func main() throws {
        let fixture = """
        (This file must be converted with BinHex 4.0)

        :$'GbC@9dD@jR,R4iG!"849K8G(4iG(!!N!34!!!!"q2c3QPZ5'9i)("KH@a[B@5
        3!!d+ImG58e*$!*!!rjEU:
        """
        let expectedData = Data("BinHex payload".utf8) + Data([0x90, 0x0d, 0x0a])
        let expectedResource = Data([0x52, 0x53, 0x52, 0x43, 0x00, 0x90, 0xff])
        let result = try MIDecoder.decode(fixture, as: .binHex)
        precondition(result.data == expectedData, "BinHex data fork mismatch")
        precondition(result.resourceFork == expectedResource, "BinHex resource fork mismatch")
        precondition(result.suggestedFileName == "greeting.txt", "BinHex filename was not preserved")
        precondition(result.finderInfo?.prefix(8) == Data("TEXTttxt".utf8), "BinHex file type/creator metadata was not preserved")

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("retron-binhex-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        try result.write(to: output)
        let savedData = try Data(contentsOf: output)
        let savedResource = try readAttribute("com.apple.ResourceFork", at: output)
        let savedFinderInfo = try readAttribute("com.apple.FinderInfo", at: output)
        precondition(savedData == expectedData, "saved BinHex data fork mismatch")
        precondition(savedResource == expectedResource, "saved BinHex resource fork mismatch")
        precondition(savedFinderInfo == result.finderInfo, "saved BinHex Finder metadata mismatch")

        var corrupt = fixture
        let crcCharacter = corrupt.firstIndex(of: "q")!
        corrupt.replaceSubrange(crcCharacter...crcCharacter, with: "p")
        var rejected = false
        do { _ = try MIDecoder.decode(corrupt, as: .binHex) } catch { rejected = true }
        precondition(rejected, "damaged BinHex CRC was accepted")
        print("BinHex HQX/RLE decoding, data/resource forks, filename, Finder metadata, and CRC rejection verified against a Python 3.9 binhex fixture")
    }

    private static func readAttribute(_ name: String, at url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard read >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return data
    }
}
