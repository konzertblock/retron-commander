import Foundation

struct MIMEAttachment: Identifiable, Sendable {
    let id: String
    let fileName: String
    let contentType: String
    let decoded: DecodedMIMEFile
}

enum MIMEAttachmentExportService {
    static func export(_ attachments: [MIMEAttachment], to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for attachment in attachments {
            let target = uniqueURL(for: safeName(attachment.fileName), in: directory)
            try attachment.decoded.write(to: target)
            written.append(target)
        }
        return written
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "attachment.bin" : cleaned
    }

    private static func uniqueURL(for name: String, in directory: URL) -> URL {
        let requested = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let stem = requested.deletingPathExtension().lastPathComponent
        let ext = requested.pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

enum MIMEMessageParser {
    static func parse(_ message: Data) throws -> [MIMEAttachment] {
        var attachments: [MIMEAttachment] = []
        var nextID = 0
        try parseEntity(message, depth: 0, nextID: &nextID, into: &attachments)
        return attachments
    }

    private static func parseEntity(_ entity: Data, depth: Int, nextID: inout Int, into attachments: inout [MIMEAttachment]) throws {
        guard depth <= 16, let (headerData, body) = splitHeader(entity),
              let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw MIMEError.invalidData("MIME message")
        }
        let headers = parseHeaders(headerText)
        let contentType = headers["content-type"] ?? "text/plain"
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType), !boundary.isEmpty else {
                throw MIMEError.invalidData("MIME multipart boundary")
            }
            let parsedParts = multipartParts(body, boundary: boundary)
            guard parsedParts.sawOpening, parsedParts.sawClosing else { throw MIMEError.invalidData("MIME multipart boundary") }
            for part in parsedParts.parts {
                try parseEntity(part, depth: depth + 1, nextID: &nextID, into: &attachments)
            }
            return
        }

        let disposition = headers["content-disposition"] ?? ""
        let rawName = continuedParameter("filename", in: disposition)
            ?? continuedParameter("name", in: contentType)
            ?? parameter("filename*", in: disposition)
            ?? parameter("filename", in: disposition)
            ?? parameter("name*", in: contentType)
            ?? parameter("name", in: contentType)
        let name = rawName.map(decodeEncodedWords)
        let dispositionType = disposition.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isAttachment = name != nil || dispositionType == "attachment" || (!mediaType.hasPrefix("text/") && mediaType != "message/delivery-status")
        guard isAttachment else { return }

        let transferEncoding = (headers["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var decoded: DecodedMIMEFile
        switch transferEncoding {
        case "", "7bit", "8bit", "binary":
            decoded = DecodedMIMEFile(data: body)
        case "base64":
            decoded = try MIDecoder.decode(String(decoding: body, as: UTF8.self), as: .base64)
        case "quoted-printable":
            decoded = try MIDecoder.decode(String(decoding: body, as: UTF8.self), as: .quotedPrintable)
        case "uuencode", "x-uuencode", "uue":
            decoded = try MIDecoder.decode(String(decoding: body, as: UTF8.self), as: .uuencode)
        case "xxencode", "x-xxencode", "xxe":
            decoded = try MIDecoder.decode(String(decoding: body, as: UTF8.self), as: .xxencode)
        case "yenc", "x-yenc":
            decoded = try MIDecoder.decode(String(decoding: body, as: UTF8.self), as: .yenc)
        case "binhex", "x-binhex40", "mac-binhex40":
            decoded = try MIDecoder.decode(String(decoding: body, as: UTF8.self), as: .binHex)
        default:
            throw MIMEError.invalidData("MIME transfer encoding: \(transferEncoding)")
        }

        let fallbackName = name ?? decoded.suggestedFileName ?? defaultFileName(for: mediaType, index: nextID + 1)
        nextID += 1
        attachments.append(MIMEAttachment(id: "attachment-\(nextID)", fileName: fallbackName, contentType: mediaType, decoded: decoded))
    }

    private static func splitHeader(_ entity: Data) -> (Data, Data)? {
        let separators = [Data([13, 10, 13, 10]), Data([10, 10])]
        let matches = separators.compactMap { separator -> (Int, Int)? in
            guard let range = find(separator, in: entity, from: 0) else { return nil }
            return (range.lowerBound, range.upperBound)
        }
        guard let match = matches.min(by: { $0.0 < $1.0 }) else { return nil }
        return (Data(entity[..<match.0]), Data(entity[match.1...]))
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var unfolded: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = headers[key].map { $0 + ", " + value } ?? value
        }
        return headers
    }

    private static func multipartParts(_ body: Data, boundary: String) -> (parts: [Data], sawOpening: Bool, sawClosing: Bool) {
        let opening = Array("--\(boundary)".utf8)
        var parts: [Data] = []
        var partStart: Int?
        var sawOpening = false
        var sawClosing = false
        var lineStart = 0
        while lineStart <= body.count {
            var lineEnd = lineStart
            while lineEnd < body.count && body[lineEnd] != 0x0A { lineEnd += 1 }
            var line = Array(body[lineStart..<lineEnd])
            if line.last == 0x0D { line.removeLast() }
            while line.last == 0x20 || line.last == 0x09 { line.removeLast() }
            if line.starts(with: opening) {
                let suffix = Array(line.dropFirst(opening.count))
                if suffix.isEmpty || suffix == [0x2D, 0x2D] {
                    if let partStart {
                        var partEnd = lineStart
                        if partEnd >= 2 && body[partEnd - 2] == 0x0D && body[partEnd - 1] == 0x0A { partEnd -= 2 }
                        else if partEnd >= 1 && body[partEnd - 1] == 0x0A { partEnd -= 1 }
                        if partEnd >= partStart { parts.append(Data(body[partStart..<partEnd])) }
                    }
                    if suffix == [0x2D, 0x2D] {
                        sawClosing = true
                        break
                    }
                    sawOpening = true
                    partStart = lineEnd < body.count ? lineEnd + 1 : body.count
                }
            }
            if lineEnd == body.count { break }
            lineStart = lineEnd + 1
        }
        return (parts, sawOpening, sawClosing)
    }

    private static func parameter(_ key: String, in header: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: "(?:^|;)\\s*\(escaped)\\s*=\\s*(?:\"((?:\\\\.|[^\"])*)\"|([^;\\s]*))",
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        let range = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: header) }.first
        guard let range else { return nil }
        var value = String(header[range]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        if key.lowercased().hasSuffix("*") {
            if let firstQuote = value.firstIndex(of: "'"), let secondQuote = value[value.index(after: firstQuote)...].firstIndex(of: "'") {
                value = String(value[value.index(after: secondQuote)...]).removingPercentEncoding ?? String(value[value.index(after: secondQuote)...])
            }
        }
        return value.isEmpty ? nil : value
    }

    private static func continuedParameter(_ key: String, in header: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: "(?:^|;)\\s*\(escaped)\\*(\\d+)(\\*)?\\s*=\\s*(?:\"((?:\\\\.|[^\"])*)\"|([^;\\s]*))",
            options: [.caseInsensitive]
        ) else { return nil }

        struct Segment {
            let value: String
            let extended: Bool
        }
        var segments: [Int: Segment] = [:]
        for match in expression.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
            guard let indexRange = Range(match.range(at: 1), in: header),
                  let index = Int(header[indexRange]), index >= 0, index < 128 else { continue }
            let extended = match.range(at: 2).location != NSNotFound
            let valueRange = [3, 4].compactMap { Range(match.range(at: $0), in: header) }.first
            guard let valueRange, segments[index] == nil else { continue }
            let value = String(header[valueRange])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            segments[index] = Segment(value: value, extended: extended)
        }
        guard !segments.isEmpty, segments[0] != nil else { return nil }
        let indices = segments.keys.sorted()
        guard indices.first == 0, indices.count <= 128,
              indices.enumerated().allSatisfy({ $0.offset == $0.element }) else { return nil }
        let ordered = indices.compactMap { segments[$0] }
        var charset = "utf-8"
        var languageAndPayload = false
        var bytes = Data()
        for (index, segment) in ordered.enumerated() {
            var value = segment.value
            if segment.extended, index == 0,
               let firstQuote = value.firstIndex(of: "'"),
               let secondQuote = value[value.index(after: firstQuote)...].firstIndex(of: "'") {
                charset = String(value[..<firstQuote])
                value = String(value[value.index(after: secondQuote)...])
                languageAndPayload = true
            }
            if segment.extended || languageAndPayload {
                guard let decoded = percentDecodedBytes(value) else { return nil }
                bytes.append(decoded)
            } else {
                bytes.append(contentsOf: value.utf8)
            }
        }
        return String(data: bytes, encoding: mimeStringEncoding(charset)) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func percentDecodedBytes(_ value: String) -> Data? {
        let source = Array(value.utf8)
        var output = Data()
        var index = 0
        while index < source.count {
            if source[index] == 0x25 {
                guard index + 2 < source.count,
                      let high = hexNibble(source[index + 1]),
                      let low = hexNibble(source[index + 2]) else { return nil }
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(source[index])
                index += 1
            }
        }
        return output
    }

    private static func hexNibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 55
        case 97...102: value - 87
        default: nil
        }
    }

    private static func mimeStringEncoding(_ name: String) -> String.Encoding {
        switch name.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "us-ascii", "ascii": .ascii
        case "iso-8859-1", "latin1", "latin-1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "utf-16", "utf-16le": .utf16LittleEndian
        case "utf-16be": .utf16BigEndian
        default: .utf8
        }
    }

    private static func defaultFileName(for mediaType: String, index: Int) -> String {
        let subtype = mediaType.split(separator: "/").last.map(String.init) ?? "bin"
        let suffix = subtype == "octet-stream" ? "bin" : subtype.replacingOccurrences(of: "+", with: "-")
        return "attachment-\(index).\(suffix)"
    }

    private static func decodeEncodedWords(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]+)\\?="),
              !expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).isEmpty else { return value }
        var result = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let word = String(result[range])
            guard let fields = try? NSRegularExpression(pattern: "^=\\?([^?]+)\\?([bBqQ])\\?([^?]+)\\?=$"),
                  let parts = fields.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)),
                  let charsetRange = Range(parts.range(at: 1), in: word),
                  let methodRange = Range(parts.range(at: 2), in: word),
                  let payloadRange = Range(parts.range(at: 3), in: word) else { continue }
            let charset = String(word[charsetRange]).lowercased()
            let method = word[methodRange].lowercased()
            let payload = String(word[payloadRange])
            let data: Data?
            if method == "b" {
                data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
            } else {
                let qBytes = Data(payload.replacingOccurrences(of: "_", with: " ").utf8)
                data = try? MIDecoder.decode(String(decoding: qBytes, as: UTF8.self), as: .quotedPrintable).data
            }
            guard let data else { continue }
            let encoding: String.Encoding = charset == "iso-8859-1" || charset == "latin1" ? .isoLatin1 : .utf8
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            result.replaceSubrange(range, with: decoded)
        }
        return result
    }

    private static func find(_ pattern: Data, in data: Data, from start: Int) -> Range<Int>? {
        guard !pattern.isEmpty, data.count >= pattern.count, start <= data.count - pattern.count else { return nil }
        for index in start...(data.count - pattern.count) where data[index..<(index + pattern.count)].elementsEqual(pattern) {
            return index..<(index + pattern.count)
        }
        return nil
    }
}
