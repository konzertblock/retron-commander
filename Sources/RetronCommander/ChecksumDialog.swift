import CryptoKit
import SwiftUI

struct ChecksumDialog: View {
    private enum ManifestFormat: String, CaseIterable, Identifiable {
        case sfv, md5, sha1, sha256, sha512
        var id: String { rawValue.uppercased() }
        var title: String { id }
    }
    let files: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var results: [String] = []
    @State private var error: String?
    @State private var isWorking = true
    @State private var format: ManifestFormat = .sfv

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checksums").font(.headline)
            Text(files.map(\.lastPathComponent).joined(separator: ", "))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            if isWorking { ProgressView("Calculating CRC32, MD5, SHA-1, SHA-256 and SHA-512…").frame(maxWidth: .infinity, minHeight: 100) }
            else if let error { ContentUnavailableView("Could Not Calculate Checksums", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                            Text(result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }.padding(10)
                }.background(Color(nsColor: .textBackgroundColor))
            }
            HStack {
                Picker("Create", selection: $format) {
                    ForEach(ManifestFormat.allCases) { format in Text(format.title).tag(format) }
                }.frame(width: 140)
                Button("Create Hash File…") { createManifest() }.disabled(files.isEmpty || isWorking)
                Button("Verify Hash File…") { verifyManifest() }
                Button("Copy Results") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(results.joined(separator: "\n\n"), forType: .string)
                }.disabled(results.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 540, minHeight: 360)
        .task { calculate() }
    }

    private func calculate() {
        Task.detached(priority: .userInitiated) {
            do {
                let values = try files.map { try ChecksumService.calculate($0) }
                await MainActor.run { results = values; isWorking = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isWorking = false }
            }
        }
    }

    private func verifyManifest() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Verify"
        guard panel.runModal() == .OK, let manifest = panel.url else { return }
        isWorking = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let output = try ChecksumManifestService.verify(manifest)
                await MainActor.run { results = output; isWorking = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isWorking = false }
            }
        }
    }

    private func createManifest() {
        guard let first = files.first else { return }
        let directory = first.deletingLastPathComponent()
        guard files.allSatisfy({ $0.deletingLastPathComponent() == directory }) else {
            error = "Manifest creation requires all selected files to be in the same folder."
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = "checksums.\(format.rawValue)"
        panel.canCreateDirectories = false
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isWorking = true
        error = nil
        let selectedFormat = format
        Task.detached(priority: .userInitiated) {
            do {
                try ChecksumManifestService.create(files, at: destination, format: selectedFormat.rawValue)
                await MainActor.run {
                    results = ["Created \(destination.lastPathComponent)", "\(files.count) file(s) · \(selectedFormat.title)"]
                    isWorking = false
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isWorking = false }
            }
        }
    }
}

private enum ChecksumService {
    static func calculate(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha512 = SHA512()
        var crc: UInt32 = 0xFFFF_FFFF
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            sha512.update(data: chunk)
            for byte in chunk {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
        }
        let finalCRC = crc ^ 0xFFFF_FFFF
        return "\(url.lastPathComponent)\nCRC32   \(String(format: "%08X", finalCRC))\nMD5     \(hex(md5.finalize()))\nSHA-1   \(hex(sha1.finalize()))\nSHA-256 \(hex(sha256.finalize()))\nSHA-512 \(hex(sha512.finalize()))"
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ChecksumManifestService {
    private enum Algorithm { case crc32, md5, sha1, sha256, sha512 }

    static func verify(_ manifest: URL) throws -> [String] {
        guard let algorithm = algorithm(for: manifest.pathExtension) else { throw ManifestError.unsupported(manifest.pathExtension) }
        let contents = try String(contentsOf: manifest, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines)
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";") else { continue }
            guard let (name, expected) = parse(trimmed, algorithm: algorithm) else { continue }
            let file = manifest.deletingLastPathComponent().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                output.append("MISSING  \(name)")
                continue
            }
            let actual = try digest(file, algorithm: algorithm)
            output.append("\(actual.caseInsensitiveCompare(expected) == .orderedSame ? "OK" : "FAILED")  \(name)")
            if actual.caseInsensitiveCompare(expected) != .orderedSame {
                output.append("  expected \(expected.lowercased())\n  actual   \(actual.lowercased())")
            }
        }
        guard !output.isEmpty else { throw ManifestError.noEntries }
        return output
    }

    static func create(_ files: [URL], at destination: URL, format: String) throws {
        guard let algorithm = algorithm(for: format), !files.isEmpty else { throw ManifestError.unsupported(format) }
        let rows = try files.map { file -> String in
            let hash = try digest(file, algorithm: algorithm)
            return switch algorithm {
            case .crc32: "\(file.lastPathComponent) \(hash.uppercased())"
            case .md5, .sha1, .sha256, .sha512: "\(hash) *\(file.lastPathComponent)"
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
    }

    private static func algorithm(for ext: String) -> Algorithm? {
        switch ext.lowercased() {
        case "sfv": .crc32
        case "md5": .md5
        case "sha1": .sha1
        case "sha256": .sha256
        case "sha512": .sha512
        default: nil
        }
    }

    private static func parse(_ line: String, algorithm: Algorithm) -> (String, String)? {
        if let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), close > open {
            let name = String(line[line.index(after: open)..<close])
            let tail = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.hasPrefix("="), let digest = tail.split(whereSeparator: \.isWhitespace).last { return (name, String(digest)) }
        }
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 2 else { return nil }
        let digestLength: Int = switch algorithm { case .crc32: 8; case .md5: 32; case .sha1: 40; case .sha256: 64; case .sha512: 128 }
        if tokens[0].count == digestLength, tokens[0].allSatisfy(\.isHexDigit) {
            let rest = line.dropFirst(tokens[0].count).trimmingCharacters(in: .whitespacesAndNewlines)
            return (rest.hasPrefix("*") ? String(rest.dropFirst()) : rest, String(tokens[0]))
        }
        guard let last = tokens.last, last.count == digestLength, last.allSatisfy(\.isHexDigit) else { return nil }
        let name = line.dropLast(last.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, String(last))
    }

    private static func digest(_ url: URL, algorithm: Algorithm) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
        var crc: UInt32 = 0xFFFF_FFFF
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            switch algorithm {
            case .crc32:
                for byte in data {
                    crc ^= UInt32(byte)
                    for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
                }
            case .md5: md5.update(data: data)
            case .sha1: sha1.update(data: data)
            case .sha256: sha256.update(data: data)
            case .sha512: sha512.update(data: data)
            }
        }
        let bytes: [UInt8] = switch algorithm {
        case .crc32: withUnsafeBytes(of: (crc ^ 0xFFFF_FFFF).bigEndian, Array.init)
        case .md5: Array(md5.finalize())
        case .sha1: Array(sha1.finalize())
        case .sha256: Array(sha256.finalize())
        case .sha512: Array(sha512.finalize())
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ManifestError: LocalizedError {
    case unsupported(String), noEntries
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): "Unsupported checksum manifest type: .\(ext)"
        case .noEntries: "No supported checksum entries were found in the selected manifest."
        }
    }
}
