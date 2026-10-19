import CryptoKit
import SwiftUI

private enum SplitMode: String, CaseIterable, Identifiable {
    case size = "Maximum part size"
    case count = "Number of parts"
    var id: String { rawValue }
}

struct SplitJoinDialog: View {
    let entries: [FileEntry]
    let completed: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chunkSizeMB = "100"
    @State private var numberOfParts = "2"
    @State private var splitMode: SplitMode = .size
    @State private var includeOriginalExtension = true
    @State private var createCombineScript = true
    @State private var message = "Select one file to split, or a numbered part to combine."
    @State private var error: String?
    @State private var isWorking = false

    private var selectedFile: URL? { entries.first(where: { !$0.isDirectory && !$0.isParent })?.url }
    private var isSegment: Bool { selectedFile.map(SplitJoinService.isPart) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split / Combine File").font(.headline)
            Text(selectedFile?.path ?? "No file selected")
                .font(.system(size: 11, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
            if !isSegment {
                HStack(spacing: 8) {
                    Picker("Split by", selection: $splitMode) {
                        ForEach(SplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .frame(width: 180)
                    if splitMode == .size {
                        TextField("100", text: $chunkSizeMB).frame(width: 90)
                        Text("MB per part")
                    } else {
                        TextField("2", text: $numberOfParts).frame(width: 90)
                        Text("parts")
                    }
                }
                Toggle("Include the original extension in part names", isOn: $includeOriginalExtension)
                Toggle("Create a macOS combine .command file with SHA-256 verification", isOn: $createCombineScript)
                Text("Parts use Retron-compatible .001, .002… names.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Text(message).font(.system(size: 11)).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Working…" : isSegment ? "Combine" : "Split") { perform() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || selectedFile == nil)
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    private func perform() {
        guard let selectedFile else { return }
        let joinMode = isSegment
        let partSizeText = chunkSizeMB
        let partCountText = numberOfParts
        let mode = splitMode
        let includeExtension = includeOriginalExtension
        let makeCombineScript = createCombineScript
        isWorking = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let outputs: [URL]
                let status: String
                if joinMode {
                    let joined = try SplitJoinService.join(from: selectedFile)
                    outputs = [joined.url]
                    status = joined.verified ? "Combined; CRC32 or SHA-256 verified." : "Combined; no checksum metadata was available."
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: selectedFile.path)
                    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    let size: Int64
                    if mode == .size {
                        guard let mb = Int(partSizeText), (1...4096).contains(mb) else { throw SplitJoinError.invalidChunkSize }
                        size = Int64(mb) * 1024 * 1024
                    } else {
                        guard let count = Int(partCountText), (1...999).contains(count) else { throw SplitJoinError.invalidPartCount }
                        size = max(1, (bytes + Int64(count) - 1) / Int64(count))
                    }
                    outputs = try SplitJoinService.split(selectedFile, chunkBytes: size, includeExtension: includeExtension, createCombineScript: makeCombineScript)
                    let parts = outputs.filter { SplitJoinService.isPart($0) }.count
                    status = "Created \(parts) Retron-compatible numbered parts\(makeCombineScript ? " and a SHA-256 verified macOS .command script" : "")."
                }
                await MainActor.run { completed(outputs); message = status; isWorking = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; isWorking = false }
            }
        }
    }
}

private enum SplitJoinService {
    private struct Segment { let url: URL; let index: Int; let baseName: String; let style: String }
    private struct BatchMetadata { let name: String?; let crc: String? }

    static func isPart(_ url: URL) -> Bool { segment(for: url) != nil }

    static func split(_ file: URL, chunkBytes: Int64, includeExtension: Bool, createCombineScript: Bool) throws -> [URL] {
        guard !file.lastPathComponent.contains("\n"), !file.lastPathComponent.contains("\r") else { throw SplitJoinError.unsafeName }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let count = max(1, Int((size + chunkBytes - 1) / chunkBytes))
        guard count <= 999 else { throw SplitJoinError.invalidPartCount }
        let partBase = includeExtension ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
        let outputs = (1...count).map { partURL(file, baseName: partBase, index: $0) }
        let combineScript = file.deletingLastPathComponent().appendingPathComponent(partBase + ".command")
        guard outputs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }),
              !FileManager.default.fileExists(atPath: manifestURL(file).path),
              !createCombineScript || !FileManager.default.fileExists(atPath: combineScript.path) else { throw SplitJoinError.destinationExists }

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var sha256 = SHA256()
        var crc = CRC32State()
        var created: [URL] = []
        do {
            for output in outputs {
                FileManager.default.createFile(atPath: output.path, contents: nil)
                created.append(output)
                let part = try FileHandle(forWritingTo: output)
                var remaining = chunkBytes
                while remaining > 0, let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty {
                    try part.write(contentsOf: data)
                    sha256.update(data: data)
                    crc.update(data)
                    remaining -= Int64(data.count)
                }
                try part.close()
            }
            let digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
            if createCombineScript {
                let contents = makeCombineScript(originalName: file.lastPathComponent, partBase: partBase, partCount: count, crc: crc.finalValue, sha256: digest)
                try Data(contents.utf8).write(to: combineScript, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: combineScript.path)
                created.append(combineScript)
            }
            // Retain the app's digest sidecar for subsequent verified joins.
            let manifest = manifestURL(file)
            try Data("SHA256 \(digest)\nFILE \(file.lastPathComponent)\nPARTS \(count)\n".utf8).write(to: manifest, options: .withoutOverwriting)
            created.append(manifest)
            return created
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    static func join(from selected: URL) throws -> (url: URL, verified: Bool) {
        guard let chosen = segment(for: selected) else { throw SplitJoinError.notPart }
        let directory = selected.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let parts = files.compactMap(segment)
            .filter { $0.baseName == chosen.baseName && $0.style == chosen.style }
            .sorted { $0.index < $1.index }
        guard !parts.isEmpty, parts.first?.index == 1 else { throw SplitJoinError.missingPart }
        for (offset, part) in parts.enumerated() where part.index != offset + 1 { throw SplitJoinError.missingPart }

        let batchURL = directory.appendingPathComponent(chosen.baseName + ".command")
        let legacyBatchURL = directory.appendingPathComponent(chosen.baseName + ".bat")
        let metadata = readBatchMetadata(FileManager.default.fileExists(atPath: batchURL.path) ? batchURL : legacyBatchURL)
        if let name = metadata.name,
           name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\\") {
            throw SplitJoinError.unsafeName
        }
        let output = directory.appendingPathComponent(metadata.name ?? chosen.baseName)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw SplitJoinError.destinationExists }
        let temporary = directory.appendingPathComponent(".retron-join-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let destination = try FileHandle(forWritingTo: temporary)
        var sha256 = SHA256()
        var crc = CRC32State()
        do {
            for part in parts {
                let input = try FileHandle(forReadingFrom: part.url)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try destination.write(contentsOf: data)
                    sha256.update(data: data)
                    crc.update(data)
                }
            }
            try destination.close()
            if let expectedCRC = metadata.crc, String(format: "%08X", crc.finalValue) != expectedCRC.uppercased() {
                throw SplitJoinError.checksumMismatch
            }
            let digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
            let manifest = manifestURL(output)
            var shaVerified = false
            if FileManager.default.fileExists(atPath: manifest.path) {
                let contents = try String(contentsOf: manifest, encoding: .utf8)
                let expected = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("SHA256 ") }).map { String($0.dropFirst(7)) }
                guard expected == digest else { throw SplitJoinError.checksumMismatch }
                shaVerified = true
            }
            try FileManager.default.moveItem(at: temporary, to: output)
            return (output, shaVerified || metadata.crc != nil)
        } catch {
            try? destination.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func segment(for url: URL) -> Segment? {
        if ["bat", "command"].contains(url.pathExtension.lowercased()) {
            let base = url.deletingPathExtension().lastPathComponent
            let firstPart = url.deletingLastPathComponent().appendingPathComponent(base + ".001")
            if FileManager.default.fileExists(atPath: firstPart.path) {
                return Segment(url: url, index: 1, baseName: base, style: "retron")
            }
        }
        let patterns = [("^(.*)\\.part([0-9]{3,})$", "part"), ("^(.*)\\.([0-9]{1,3})$", "retron")]
        for (pattern, style) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: url.lastPathComponent, range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)),
                  let baseRange = Range(match.range(at: 1), in: url.lastPathComponent),
                  let indexRange = Range(match.range(at: 2), in: url.lastPathComponent),
                  let index = Int(url.lastPathComponent[indexRange]) else { continue }
            return Segment(url: url, index: index, baseName: String(url.lastPathComponent[baseRange]), style: style)
        }
        return nil
    }

    private static func partURL(_ file: URL, baseName: String, index: Int) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("\(baseName).\(String(format: "%03d", index))")
    }

    private static func outputURL(for part: URL) -> URL {
        let name = part.lastPathComponent.replacingOccurrences(of: #"\.part[0-9]{3,}$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return part.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func manifestURL(_ file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".retron.sha256")
    }

    private static func makeCombineScript(originalName: String, partBase: String, partCount: Int, crc: UInt32, sha256: String) -> String {
        let output = shellQuote(originalName)
        let temporary = shellQuote(".\(originalName).retron-join.tmp")
        let parts = (1...partCount).map { shellQuote("./\(partBase).\(String(format: "%03d", $0))") }.joined(separator: " ")
        return """
        #!/bin/sh
        # name=\(originalName)
        # crc32=\(String(format: "%08X", crc))
        # sha256=\(sha256)
        set -eu
        script_dir=$(/usr/bin/dirname "$0")
        cd "$script_dir"
        output=\(output)
        temporary=\(temporary)
        trap '/bin/rm -f "$temporary"' EXIT HUP INT TERM
        if [ -d "$output" ]; then
          echo "The output path is a directory; original file was not replaced." >&2
          exit 1
        fi
        /bin/cat \(parts) > "$temporary"
        actual=$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')
        if [ "$actual" != '\(sha256)' ]; then
          echo "SHA-256 verification failed; original file was not replaced." >&2
          exit 1
        fi
        /bin/mv -f "$temporary" "$output"
        trap - EXIT HUP INT TERM
        echo "Reconstructed and verified: $output"
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readBatchMetadata(_ file: URL) -> BatchMetadata {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return BatchMetadata(name: nil, crc: nil) }
        var name: String?, crc: String?
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.hasPrefix("rem name=") || lower.hasPrefix("# name=") { name = String(line.dropFirst(lower.hasPrefix("rem ") ? 9 : 7)).trimmingCharacters(in: .whitespacesAndNewlines) }
            if lower.hasPrefix("rem crc32=") || lower.hasPrefix("# crc32=") { crc = String(line.dropFirst(lower.hasPrefix("rem ") ? 10 : 8)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return BatchMetadata(name: name, crc: crc)
    }
}

private struct CRC32State {
    private var value: UInt32 = 0xFFFF_FFFF
    mutating func update(_ data: Data) {
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        }
    }
    var finalValue: UInt32 { value ^ 0xFFFF_FFFF }
}

private enum SplitJoinError: LocalizedError {
    case invalidChunkSize, invalidPartCount, destinationExists, notPart, missingPart, checksumMismatch, unsafeName
    var errorDescription: String? {
        switch self {
        case .invalidChunkSize: "Part size must be between 1 MB and 4096 MB."
        case .invalidPartCount: "The split operation supports between 1 and 999 parts."
        case .destinationExists: "A destination part, manifest, combine script, or combined file already exists."
        case .notPart: "Select a numbered file part first."
        case .missingPart: "A part is missing or the selected parts are not numbered consecutively from .001."
        case .checksumMismatch: "The reconstructed file does not match its CRC32 or SHA-256 metadata."
        case .unsafeName: "The source or companion metadata contains an unsafe output filename."
        }
    }
}
