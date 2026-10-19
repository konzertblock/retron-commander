import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MultimediaInfoRow: Identifiable {
    let id: String
    let value: String
}

enum MultimediaInfoReader {
    static let extensions: Set<String> = [
        "mp3", "mp2", "ogg", "oga", "wav", "wave", "wma", "vqf", "aac", "mp4", "m4a", "m4b",
        "669", "it", "mod", "mtm", "s3m", "stm", "xm"
    ]

    static func read(_ file: URL) async throws -> [MultimediaInfoRow] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        var values: [(String, String)] = [
            ("File", file.lastPathComponent),
            ("Format", file.pathExtension.uppercased().isEmpty ? "Unknown" : file.pathExtension.uppercased()),
            ("Size", ByteCountFormatter.string(fromByteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0, countStyle: .file)),
            ("Modified", (attributes[.modificationDate] as? Date)?.formatted(date: .numeric, time: .shortened) ?? "Unknown")
        ]
        if ["mp3", "mp2"].contains(file.pathExtension.lowercased()) {
            values.append(contentsOf: try ID3TagReader.read(file))
        }

        let asset = AVURLAsset(url: file)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 { values.append(("Duration", formatDuration(seconds))) }
        }
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "Metadata"
                guard let text = try? await item.load(.stringValue), !text.isEmpty else { continue }
                values.append((key, text))
            }
        }
        if let tracks = try? await asset.load(.tracks) {
            for (index, track) in tracks.enumerated() {
                let type = track.mediaType.rawValue
                values.append(("Track \(index + 1)", type))
                if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                    values.append(("Track \(index + 1) bitrate", "\(Int(rate / 1000)) kbps"))
                }
            }
        }
        return values.enumerated().map { index, pair in
            MultimediaInfoRow(id: "\(index)-\(pair.0)", value: "\(pair.0)\t\(pair.1)")
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }

    static func html(for file: URL, rows: [MultimediaInfoRow]) -> String {
        let body = rows.map { row -> String in
            let parts = row.value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.dropFirst().first.map(String.init) ?? ""
            return "<tr><th>\(escape(key))</th><td>\(escape(value))</td></tr>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(file.lastPathComponent))</title>
        <style>body{font:14px -apple-system,sans-serif;margin:2em}table{border-collapse:collapse}th,td{padding:.45em .8em;border:1px solid #bbb;text-align:left}th{background:#eee}</style>
        </head><body><h1>Multimedia information</h1><table>\(body)</table></body></html>
        """
    }

    static func html(for reports: [MultimediaInfoReport]) -> String {
        let sections = reports.map { report in
            let rows = report.rows.map { row -> String in
                let parts = row.value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts.first.map(String.init) ?? ""
                let value = parts.dropFirst().first.map(String.init) ?? ""
                return "<tr><th>\(escape(key))</th><td>\(escape(value))</td></tr>"
            }.joined(separator: "\n")
            return "<section><h2>\(escape(report.file.lastPathComponent))</h2><table>\(rows)</table></section>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Multimedia information</title>
        <style>body{font:14px -apple-system,sans-serif;margin:2em}table{border-collapse:collapse}th,td{padding:.45em .8em;border:1px solid #bbb;text-align:left}th{background:#eee}section{margin-bottom:2em}</style>
        </head><body><h1>Multimedia information</h1>\(sections)</body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct MultimediaInfoReport: Identifiable {
    let file: URL
    let rows: [MultimediaInfoRow]
    var id: String { file.path }
}

enum ID3TagReader {
    private static let v1Fields: [(String, Range<Int>)] = [
        ("Title", 3..<33), ("Artist", 33..<63), ("Album", 63..<93), ("Year", 93..<97)
    ]
    static func read(_ file: URL) throws -> [(String, String)] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileLength = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        var result: [(String, String)] = []
        var audioStart: Int64 = 0

        let header = try handle.read(upToCount: 10) ?? Data()
        if header.count == 10, String(data: header.prefix(3), encoding: .ascii) == "ID3" {
            let major = Int(header[3])
            let size = synchsafe(header[6..<10])
            if (2...4).contains(major), let size, size <= 16 * 1024 * 1024,
               let tag = try handle.read(upToCount: size), tag.count == size {
                audioStart = Int64(10 + size)
                result.append(("ID3 version", "2.\(major).\(header[4])"))
                result.append(contentsOf: parseFrames(tag, majorVersion: major, unsynchronized: header[5] & 0x80 != 0))
            }
        }

        result.append(contentsOf: try mpegFrameInfo(file, offset: audioStart, fileLength: fileLength))

        if fileLength >= 128 {
            try handle.seek(toOffset: UInt64(fileLength - 128))
            let tag = try handle.read(upToCount: 128) ?? Data()
            if tag.count == 128, String(data: tag.prefix(3), encoding: .ascii) == "TAG" {
                result.append(("ID3 version", tag[125] == 0 && tag[126] != 0 ? "1.1" : "1.0"))
                for (key, range) in v1Fields {
                    let value = latin1(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { result.append(("ID3v1 \(key)", value)) }
                }
                let isV11 = tag[125] == 0 && tag[126] != 0
                let comment = latin1(tag[97..<(isV11 ? 125 : 127)]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !comment.isEmpty { result.append(("ID3v1 Comment", comment)) }
                if isV11 { result.append(("ID3v1 Track", String(tag[126]))) }
                result.append(("ID3v1 Genre ID", String(tag[127])))
            }
        }
        return result
    }

    private static func mpegFrameInfo(_ file: URL, offset: Int64, fileLength: Int64) throws -> [(String, String)] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = Array(try handle.read(upToCount: 1024 * 1024) ?? Data())
        guard data.count >= 4 else { return [] }
        let mpeg1Rates: [[Int]] = [
            [], [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
            [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
            [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
        ]
        let mpeg2Rates: [[Int]] = [
            [], [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
            [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
            [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
        ]
        let rates = [44_100, 48_000, 32_000]
        for index in 0..<(data.count - 3) where data[index] == 0xFF && data[index + 1] & 0xE0 == 0xE0 {
            let header = Array(data[index..<(index + 4)])
            let versionBits = (header[1] >> 3) & 0x03
            let layerBits = (header[1] >> 1) & 0x03
            let bitrateIndex = Int((header[2] >> 4) & 0x0F)
            let sampleIndex = Int((header[2] >> 2) & 0x03)
            guard versionBits != 1, layerBits != 0, bitrateIndex > 0, bitrateIndex < 15, sampleIndex < 3 else { continue }
            let mpeg1 = versionBits == 3
            let table = mpeg1 ? mpeg1Rates : mpeg2Rates
            let bitrate = table[Int(layerBits)][bitrateIndex - 1]
            var sampleRate = rates[sampleIndex]
            if versionBits == 2 { sampleRate /= 2 }
            if versionBits == 0 { sampleRate /= 4 }
            let version = versionBits == 3 ? "MPEG 1" : (versionBits == 2 ? "MPEG 2" : "MPEG 2.5")
            let layer = layerBits == 3 ? "I" : (layerBits == 2 ? "II" : "III")
            let mode = ["Stereo", "Joint stereo", "Dual channel", "Mono"][Int(header[3] >> 6)]
            let emphasis = ["None", "50/15 ms", "CCITT J.17", "Reserved"][Int(header[3] & 0x03)]
            var values: [(String, String)] = [
                ("MPEG Version", "\(version) Layer \(layer)"),
                ("Bitrate", "\(bitrate) kbps"),
                ("Sampling Frequency", "\(sampleRate) Hz"),
                ("Channel Mode", mode),
                ("Emphasis", emphasis),
                ("Copyright", header[3] & 0x08 == 0 ? "No" : "Yes"),
                ("Original", header[3] & 0x04 == 0 ? "No" : "Yes")
            ]
            var audioBytes = max(0, fileLength - offset)
            if audioBytes >= 128 {
                try handle.seek(toOffset: UInt64(fileLength - 128))
                if let tail = try handle.read(upToCount: 3), String(data: tail, encoding: .ascii) == "TAG" { audioBytes -= 128 }
            }
            if bitrate > 0 {
                let seconds = Double(audioBytes) * 8 / Double(bitrate * 1000)
                values.append(("CBR Duration Estimate", duration(seconds)))
            }
            return values
        }
        return []
    }

    private static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }

    private static func parseFrames(_ original: Data, majorVersion: Int, unsynchronized: Bool) -> [(String, String)] {
        let data = unsynchronized ? deunsynchronize(original) : original
        let shortHeader = majorVersion == 2
        let headerLength = shortHeader ? 6 : 10
        var cursor = 0
        var values: [(String, String)] = []
        let names: [String: String] = [
            "TT2": "Title", "TIT2": "Title", "TP1": "Artist", "TPE1": "Artist",
            "TAL": "Album", "TALB": "Album", "TYE": "Year", "TYER": "Year", "TDRC": "Recording Time",
            "TCO": "Genre", "TCON": "Genre", "TRK": "Track", "TRCK": "Track", "COM": "Comments", "COMM": "Comments",
            "TCM": "Composer", "TCOM": "Composer", "TP2": "Album Artist", "TPE2": "Album Artist",
            "TPB": "Publisher", "TPUB": "Publisher", "TCR": "Copyright", "TCOP": "Copyright", "TEN": "Encoded By", "TENC": "Encoded By",
            "TXX": "User Text", "TXXX": "User Text", "WCM": "Commercial URL", "WCOM": "Commercial URL",
            "WCP": "Copyright URL", "WCOP": "Copyright URL", "WAR": "Artist URL", "WOAR": "Artist URL",
            "WAS": "Audio Source URL", "WOAS": "Audio Source URL", "WRA": "Radio URL", "WORS": "Radio URL",
            "WPY": "Payment URL", "WPAY": "Payment URL", "WPB": "Publisher URL", "WPUB": "Publisher URL",
            "WXX": "User URL", "WXXX": "User URL"
        ]
        while cursor + headerLength <= data.count {
            let idLength = shortHeader ? 3 : 4
            let idData = data[cursor..<(cursor + idLength)]
            if idData.allSatisfy({ $0 == 0 }) { break }
            guard let frameID = String(data: idData, encoding: .ascii),
                  frameID.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) else { break }
            let sizeStart = cursor + idLength
            let frameSize: Int
            if shortHeader {
                frameSize = (Int(data[sizeStart]) << 16) | (Int(data[sizeStart + 1]) << 8) | Int(data[sizeStart + 2])
            } else if majorVersion == 4 {
                guard let decoded = synchsafe(data[sizeStart..<(sizeStart + 4)]) else { break }
                frameSize = decoded
            } else {
                frameSize = (Int(data[sizeStart]) << 24) | (Int(data[sizeStart + 1]) << 16) | (Int(data[sizeStart + 2]) << 8) | Int(data[sizeStart + 3])
            }
            let flagsStart = sizeStart + (shortHeader ? 3 : 4)
            let payloadStart = flagsStart + (shortHeader ? 0 : 2)
            guard frameSize >= 0, frameSize <= data.count - payloadStart else { break }
            let payload = data[payloadStart..<(payloadStart + frameSize)]
            let hasUnsupportedTransform = !shortHeader && (majorVersion == 3 ? data[flagsStart + 1] & 0xC0 != 0 : data[flagsStart + 1] & 0x4C != 0)
            if !hasUnsupportedTransform, let name = names[frameID], let text = decodeFrame(frameID, payload: Data(payload)), !text.isEmpty {
                values.append(("ID3v2 \(name)", text))
            }
            cursor = payloadStart + frameSize
        }
        return values
    }

    private static func decodeFrame(_ id: String, payload: Data) -> String? {
        guard let encoding = payload.first else { return nil }
        let content: Data
        if id == "COMM" || id == "COM" {
            guard payload.count > 4 else { return nil }
            let encodedDescription = payload.dropFirst(4)
            let terminatorLength = encoding == 1 || encoding == 2 ? 2 : 1
            var start = encodedDescription.startIndex
            while start + terminatorLength <= encodedDescription.endIndex {
                if terminatorLength == 1 && encodedDescription[start] == 0 { start += 1; break }
                if terminatorLength == 2 && encodedDescription[start] == 0 && encodedDescription[start + 1] == 0 { start += 2; break }
                start += terminatorLength
            }
            content = Data(encodedDescription[start...])
        } else if id == "TXXX" || id == "TXX" {
            let bytes = Array(payload.dropFirst())
            let terminatorLength = encoding == 1 || encoding == 2 ? 2 : 1
            var split = bytes.count
            var valueStart = bytes.count
            var cursor = 0
            while cursor + terminatorLength <= bytes.count {
                if bytes[cursor..<(cursor + terminatorLength)].allSatisfy({ $0 == 0 }) {
                    split = cursor
                    valueStart = cursor + terminatorLength
                    break
                }
                cursor += terminatorLength
            }
            let description = decodeText(encoding: encoding, bytes: Array(bytes[..<split])) ?? ""
            let value = decodeText(encoding: encoding, bytes: Array(bytes[valueStart...])) ?? ""
            return description.isEmpty ? value : "\(description): \(value)"
        } else if id.first == "T" {
            content = Data(payload.dropFirst())
        } else {
            return String(data: payload, encoding: .utf8) ?? String(decoding: payload, as: UTF8.self)
        }
        return decodeText(encoding: encoding, bytes: Array(content))?
            .components(separatedBy: "\0").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func decodeText(encoding: UInt8, bytes: [UInt8]) -> String? {
        var trimmed = bytes
        if encoding == 1 || encoding == 2 {
            while trimmed.count >= 2 && trimmed.suffix(2).allSatisfy({ $0 == 0 }) { trimmed.removeLast(2) }
        } else {
            while trimmed.last == 0 { trimmed.removeLast() }
        }
        switch encoding {
        case 0: return String(data: Data(trimmed), encoding: .isoLatin1)
        case 1:
            if trimmed.starts(with: [0xFF, 0xFE]) { return String(data: Data(trimmed.dropFirst(2)), encoding: .utf16LittleEndian) }
            if trimmed.starts(with: [0xFE, 0xFF]) { return String(data: Data(trimmed.dropFirst(2)), encoding: .utf16BigEndian) }
            return String(data: Data(trimmed), encoding: .utf16LittleEndian)
        case 2: return String(data: Data(trimmed), encoding: .utf16BigEndian)
        case 3: return String(data: Data(trimmed), encoding: .utf8)
        default: return nil
        }
    }

    private static func deunsynchronize(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var index = 0
        while index < data.count {
            result.append(data[index])
            if data[index] == 0xFF, index + 1 < data.count, data[index + 1] == 0 { index += 1 }
            index += 1
        }
        return result
    }

    private static func synchsafe(_ bytes: Data.SubSequence) -> Int? {
        guard bytes.count == 4, bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    private static func latin1(_ bytes: Data.SubSequence) -> String {
        String(data: Data(bytes.prefix { $0 != 0 }), encoding: .isoLatin1) ?? ""
    }
}

struct MultimediaViewerDialog: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MultimediaInfoRow] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform")
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Export Info into HTML…") { exportHTML() }.disabled(loading || rows.isEmpty)
            }.padding(12)
            Table(rows) {
                TableColumn("Property") { row in
                    Text(row.value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                }.width(min: 150, ideal: 190)
                TableColumn("Value") { row in
                    Text(row.value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? "")
                        .textSelection(.enabled)
                }
            }
            .overlay {
                if loading { ProgressView("Reading multimedia information…") }
                else if let error { ContentUnavailableView("Could Not Read Multimedia File", systemImage: "waveform", description: Text(error)) }
                else if rows.count <= 4 { ContentUnavailableView("No Embedded Tags", systemImage: "waveform", description: Text("The file has no metadata supported by AVFoundation. Basic file information is shown when available.")) }
            }
            HStack {
                Text("Metadata supplied by macOS media frameworks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(minWidth: 620, minHeight: 420)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do { rows = try await MultimediaInfoReader.read(file) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try MultimediaInfoReader.html(for: file, rows: rows).write(to: destination, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

private struct MultimediaExportRow: Identifiable {
    let id: String
    let file: String
    let property: String
    let value: String
}

struct MultimediaExportDialog: View {
    let files: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var reports: [MultimediaInfoReport] = []
    @State private var rows: [MultimediaExportRow] = []
    @State private var failures: [String] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform")
                Text("Export Multimedia Information").font(.headline)
                Spacer()
                Text("\(reports.count) of \(files.count) files read").foregroundStyle(.secondary)
                Button("Export HTML…") { exportHTML() }.disabled(loading || reports.isEmpty)
            }.padding(12)
            Table(rows) {
                TableColumn("File", value: \.file).width(min: 170, ideal: 230)
                TableColumn("Property", value: \.property).width(min: 130, ideal: 170)
                TableColumn("Value", value: \.value)
            }
            .overlay {
                if loading { ProgressView("Reading selected multimedia files…") }
                else if let error { ContentUnavailableView("Could Not Read Multimedia Files", systemImage: "waveform", description: Text(error)) }
                else if rows.isEmpty { ContentUnavailableView("No Multimedia Information", systemImage: "waveform") }
            }
            HStack {
                Text(failures.isEmpty ? "\(rows.count) properties from selected files" : "\(failures.count) file(s) could not be read")
                    .font(.caption).foregroundStyle(failures.isEmpty ? Color.secondary : Color.orange)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(minWidth: 780, minHeight: 480)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        reports = []
        rows = []
        failures = []
        error = nil
        for file in files {
            do {
                let fileRows = try await MultimediaInfoReader.read(file)
                let report = MultimediaInfoReport(file: file, rows: fileRows)
                reports.append(report)
                for (index, row) in fileRows.enumerated() {
                    let parts = row.value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    rows.append(MultimediaExportRow(
                        id: "\(file.path)|\(index)",
                        file: file.lastPathComponent,
                        property: parts.first.map(String.init) ?? "",
                        value: parts.dropFirst().first.map(String.init) ?? ""
                    ))
                }
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if reports.isEmpty, !failures.isEmpty { error = failures.joined(separator: "\n") }
        loading = false
    }

    private func exportHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MultimediaInfo.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try MultimediaInfoReader.html(for: reports).write(to: destination, atomically: true, encoding: .utf8) }
        catch let saveError { self.error = saveError.localizedDescription }
    }
}
