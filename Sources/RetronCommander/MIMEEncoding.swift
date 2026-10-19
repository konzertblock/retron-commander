import Foundation
import Darwin

enum MIMEEncoding: String, CaseIterable, Identifiable {
    case base64 = "Base64"
    case quotedPrintable = "Quoted-printable"
    case uuencode = "UUEncode"
    case xxencode = "XXEncode"
    case yenc = "yEnc"
    case binHex = "BinHex"
    var id: String { rawValue }
}

struct DecodedMIMEFile: Sendable {
    let data: Data
    let resourceFork: Data?
    let suggestedFileName: String?
    let finderInfo: Data?

    init(data: Data, resourceFork: Data? = nil, suggestedFileName: String? = nil, finderInfo: Data? = nil) {
        self.data = data
        self.resourceFork = resourceFork
        self.suggestedFileName = suggestedFileName
        self.finderInfo = finderInfo
    }

    func write(to url: URL) throws {
        try data.write(to: url, options: .atomic)
        if let resourceFork, !resourceFork.isEmpty {
            try setExtendedAttribute("com.apple.ResourceFork", data: resourceFork, at: url)
        }
        if let finderInfo {
            try setExtendedAttribute("com.apple.FinderInfo", data: finderInfo, at: url)
        }
    }

    private func setExtendedAttribute(_ name: String, data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

enum MIMEError: LocalizedError {
    case invalidData(String)
    case inputTooLarge
    case decodedOutputTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidData(let format): "The input is not valid \(format) data."
        case .inputTooLarge: "Input files larger than 32 MB are not loaded into this decoder."
        case .decodedOutputTooLarge: "The decoded output exceeds the 256 MB safety limit."
        }
    }
}

enum MIDecoder {
    private static let binHexAlphabet = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)
    private static let maximumDecodedSize = 256 * 1024 * 1024

    static func decode(_ input: String, as encoding: MIMEEncoding) throws -> DecodedMIMEFile {
        switch encoding {
        case .base64:
            let cleaned = input.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let value = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) else { throw MIMEError.invalidData(encoding.rawValue) }
            return DecodedMIMEFile(data: value)
        case .quotedPrintable: return DecodedMIMEFile(data: try decodeQuotedPrintable(input))
        case .uuencode: return DecodedMIMEFile(data: try decodeUU(input, alphabet: nil))
        case .xxencode: return DecodedMIMEFile(data: try decodeUU(input, alphabet: Array("+-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")))
        case .yenc: return DecodedMIMEFile(data: try decodeYEnc(input))
        case .binHex: return try decodeBinHex(input)
        }
    }

    private static func decodeBinHex(_ input: String) throws -> DecodedMIMEFile {
        let bytes = Array(input.utf8)
        guard let start = bytes.firstIndex(of: 0x3A),
              let end = bytes[(start + 1)...].firstIndex(of: 0x3A) else {
            throw MIMEError.invalidData("BinHex")
        }
        let reverse = Dictionary(uniqueKeysWithValues: binHexAlphabet.enumerated().map { ($0.element, UInt8($0.offset)) })
        var hqx = Data()
        var accumulator: UInt32 = 0
        var bitCount = 0
        for byte in bytes[(start + 1)..<end] where ![0x09, 0x0A, 0x0D, 0x20].contains(byte) {
            guard let value = reverse[byte] else { throw MIMEError.invalidData("BinHex") }
            accumulator = (accumulator << 6) | UInt32(value)
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                hqx.append(UInt8((accumulator >> bitCount) & 0xFF))
                accumulator &= bitCount == 0 ? 0 : (1 << bitCount) - 1
            }
        }

        var expanded = Data()
        expanded.reserveCapacity(hqx.count)
        var index = 0
        while index < hqx.count {
            let value = hqx[index]
            index += 1
            if value != 0x90 {
                expanded.append(value)
            } else {
                guard index < hqx.count, let previous = expanded.last else { throw MIMEError.invalidData("BinHex") }
                let repeatCount = hqx[index]
                index += 1
                if repeatCount == 0 {
                    expanded.append(0x90)
                } else {
                    let additional = Int(repeatCount) - 1
                    guard expanded.count <= maximumDecodedSize - additional else { throw MIMEError.decodedOutputTooLarge }
                    if additional > 0 { expanded.append(contentsOf: repeatElement(previous, count: additional)) }
                }
            }
            guard expanded.count <= maximumDecodedSize else { throw MIMEError.decodedOutputTooLarge }
        }

        guard let file = parseBinHexPayload(expanded) else { throw MIMEError.invalidData("BinHex") }
        return file
    }

    private static func parseBinHexPayload(_ bytes: Data) -> DecodedMIMEFile? {
        guard bytes.count >= 1 else { return nil }
        let nameLength = Int(bytes[0])
        guard (1...63).contains(nameLength) else { return nil }
        let fixedHeaderStart = 1 + nameLength
        let fixedHeaderEnd = fixedHeaderStart + 19
        guard bytes.count >= fixedHeaderEnd + 2 else { return nil }
        let filenameBytes = bytes[1..<fixedHeaderStart]
        guard bytes[fixedHeaderStart] == 0 else { return nil }
        let headerCRC = UInt16(bytes[fixedHeaderEnd]) << 8 | UInt16(bytes[fixedHeaderEnd + 1])
        let headerRange = 0..<fixedHeaderEnd
        guard crc16BinHex(bytes[headerRange]) == headerCRC else { return nil }

        let typeStart = fixedHeaderStart + 1
        let creatorStart = typeStart + 4
        let flagsStart = creatorStart + 4
        let dataLengthStart = flagsStart + 2
        let resourceLengthStart = dataLengthStart + 4
        let dataLength = Int(readUInt32(bytes, at: dataLengthStart))
        let resourceLength = Int(readUInt32(bytes, at: resourceLengthStart))
        guard dataLength >= 0, resourceLength >= 0,
              dataLength <= maximumDecodedSize, resourceLength <= maximumDecodedSize,
              dataLength <= maximumDecodedSize - resourceLength else { return nil }

        let dataStart = fixedHeaderEnd + 2
        let dataCRCStart = dataStart + dataLength
        let resourceStart = dataCRCStart + 2
        let resourceCRCStart = resourceStart + resourceLength
        guard resourceCRCStart + 2 <= bytes.count else { return nil }
        let data = Data(bytes[dataStart..<dataCRCStart])
        let dataCRC = UInt16(bytes[dataCRCStart]) << 8 | UInt16(bytes[dataCRCStart + 1])
        guard crc16BinHex(data) == dataCRC else { return nil }
        let resource = Data(bytes[resourceStart..<resourceCRCStart])
        let resourceCRC = UInt16(bytes[resourceCRCStart]) << 8 | UInt16(bytes[resourceCRCStart + 1])
        guard crc16BinHex(resource) == resourceCRC else { return nil }

        let filename = String(data: filenameBytes, encoding: .macOSRoman)
        guard let filename, !filename.isEmpty, !filename.contains("/") else { return nil }
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo.replaceSubrange(0..<8, with: bytes[typeStart..<(creatorStart + 4)])
        finderInfo.replaceSubrange(8..<10, with: bytes[flagsStart..<(flagsStart + 2)])
        return DecodedMIMEFile(
            data: data,
            resourceFork: resource,
            suggestedFileName: filename,
            finderInfo: finderInfo
        )
    }

    private static func crc16BinHex(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func decodeQuotedPrintable(_ input: String) throws -> Data {
        let bytes = Array(input.utf8)
        var output = [UInt8]()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x3D else { output.append(bytes[index]); index += 1; continue }
            if index + 1 < bytes.count && bytes[index + 1] == 0x0A { index += 2; continue }
            if index + 2 < bytes.count && bytes[index + 1] == 0x0D && bytes[index + 2] == 0x0A { index += 3; continue }
            guard index + 2 < bytes.count,
                  let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) else { throw MIMEError.invalidData("quoted-printable") }
            output.append(high << 4 | low)
            index += 3
        }
        return Data(output)
    }

    private static func decodeUU(_ input: String, alphabet: [Character]?) throws -> Data {
        let rows = input.components(separatedBy: .newlines)
        let dataRows: [String]
        if let start = rows.firstIndex(where: { $0.hasPrefix("begin ") }) {
            let end = rows[start...].firstIndex(where: { $0 == "end" }) ?? rows.endIndex
            dataRows = Array(rows[(start + 1)..<end])
        } else { dataRows = rows }
        var output = [UInt8]()
        var found = false
        for row in dataRows where !row.isEmpty {
            let bytes = Array(row.utf8)
            let length: Int
            if let alphabet {
                guard let first = row.first, let index = alphabet.firstIndex(of: first) else { throw MIMEError.invalidData("XXEncode") }
                length = index == 0 ? 0 : index
            } else {
                length = bytes[0] == 0x60 ? 0 : Int(bytes[0] &- 32)
            }
            guard length <= 45 else { throw MIMEError.invalidData(alphabet == nil ? "UUEncode" : "XXEncode") }
            if length == 0 { continue }
            found = true
            let encoded = Array(bytes.dropFirst())
            var line = [UInt8]()
            let requiredGroups = (length + 2) / 3
            guard encoded.count >= requiredGroups * 4 else { throw MIMEError.invalidData(alphabet == nil ? "UUEncode" : "XXEncode") }
            for character in encoded.prefix(requiredGroups * 4) {
                let value: UInt8
                if let alphabet {
                    guard let i = alphabet.firstIndex(where: { $0.asciiValue == character }) else { throw MIMEError.invalidData("XXEncode") }
                    value = UInt8(i) & 0x3F
                } else { value = (character &- 32) & 0x3F }
                line.append(value)
            }
            var decodedLine = [UInt8]()
            while line.count >= 4 {
                decodedLine.append(line[0] << 2 | line[1] >> 4)
                decodedLine.append(line[1] << 4 | line[2] >> 2)
                decodedLine.append(line[2] << 6 | line[3])
                line.removeFirst(4)
            }
            output.append(contentsOf: decodedLine.prefix(length))
        }
        guard found else { throw MIMEError.invalidData(alphabet == nil ? "UUEncode" : "XXEncode") }
        return Data(output)
    }

    private static func decodeYEnc(_ input: String) throws -> Data {
        let lines = input.components(separatedBy: .newlines).filter { !$0.hasPrefix("=ybegin") && !$0.hasPrefix("=ypart") && !$0.hasPrefix("=yend") }
        var output = [UInt8]()
        for line in lines {
            let bytes = Array(line.utf8)
            var index = 0
            while index < bytes.count {
                var value = bytes[index]
                if value == 0x3D {
                    guard index + 1 < bytes.count else { throw MIMEError.invalidData("yEnc") }
                    index += 1
                    value = bytes[index] &- 64
                }
                output.append(value &- 42)
                index += 1
            }
        }
        guard !output.isEmpty else { throw MIMEError.invalidData("yEnc") }
        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
