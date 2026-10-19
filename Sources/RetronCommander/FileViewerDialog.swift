import AppKit
import SwiftUI

struct FileViewerDialog: View {
    private let siblingFiles: [URL]
    @State private var fileIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var data = Data()
    @State private var fileSize: Int64 = 0
    @State private var currentOffset: Int64 = 0
    @State private var offsetText = "0"
    @State private var offsetIsHex = false
    @State private var showingOffsetPrompt = false
    @State private var text = ""
    @State private var isHex = false
    @State private var wraps = true
    @State private var search = ""
    @State private var findByteCursor: Int64 = 0
    @State private var findStatus = ""
    @State private var isSearching = false
    @State private var searchIsHex = false
    @State private var searchIsRegularExpression = false
    @State private var searchIsCaseSensitive = false
    @State private var searchWholeWords = false
    @State private var searchBackwards = false
    @State private var loadError: String?
    @State private var imagePreview: NSImage?
    @State private var imageScale: CGFloat = 1
    @State private var showingImageSaveAs = false

    private var windowByteCount: Int64 { isHex ? 256 * 1024 : 4 * 1024 * 1024 }
    private var file: URL { siblingFiles[fileIndex] }

    init(file: URL, siblingFiles: [URL] = []) {
        let candidates = siblingFiles.isEmpty ? [file] : siblingFiles
        self.siblingFiles = candidates
        self._fileIndex = State(initialValue: candidates.firstIndex(of: file) ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("‹ File") { openSibling(by: -1) }.disabled(siblingFiles.count < 2).help("Previous file (Backspace)")
                Button("File ›") { openSibling(by: 1) }.disabled(siblingFiles.count < 2).help("Next file (Space)")
                Picker("Mode", selection: $isHex) {
                    Text("Text").tag(false)
                    Text("Hex").tag(true)
                }.pickerStyle(.segmented).frame(width: 140)
                Toggle("Wrap", isOn: $wraps).toggleStyle(.checkbox).disabled(isHex)
                Button("‹") { page(by: -1) }.disabled(imagePreview != nil || currentOffset == 0).help("Previous data range")
                Button("›") { page(by: 1) }.disabled(imagePreview != nil || currentOffset + Int64(data.count) >= fileSize).help("Next data range")
                Button("Go to Offset…") { offsetText = offsetIsHex ? String(currentOffset, radix: 16).uppercased() : String(currentOffset); showingOffsetPrompt = true }.disabled(imagePreview != nil)
                Button("Refresh") { imagePreview == nil ? loadRange(at: currentOffset) : load() }
                if imagePreview != nil {
                    Button("Save As…") { showingImageSaveAs = true }
                        .help("Convert this image to another supported format")
                }
            }.padding(10)
            if let loadError {
                ContentUnavailableView("Could Not Read File", systemImage: "doc.questionmark", description: Text(loadError))
            } else if let imagePreview {
                VStack(spacing: 6) {
                    HStack {
                        Text("\(Int(imagePreview.size.width)) × \(Int(imagePreview.size.height)) px").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $imageScale, in: 0.1...4, step: 0.1).frame(maxWidth: 180)
                        Text("\(Int(imageScale * 100))%").font(.caption.monospacedDigit()).frame(width: 42)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: imagePreview)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imagePreview.size.width * imageScale, height: imagePreview.size.height * imageScale)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color(nsColor: .underPageBackgroundColor))
                }.padding(8)
            } else {
                ScrollView(isHex || !wraps ? [.horizontal, .vertical] : [.vertical]) {
                    Group {
                        if isHex { Text(hexDump(data)) }
                        else { Text(text).frame(maxWidth: wraps ? .infinity : nil, alignment: .leading) }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            HStack {
                TextField(searchIsHex ? "Find bytes in file" : "Find in file", text: $search).textFieldStyle(.roundedBorder)
                    .onSubmit { findNext() }
                    .onChange(of: search) { _, _ in findByteCursor = currentOffset }
                Menu("Find Options") {
                    Toggle("HEX mode", isOn: $searchIsHex)
                    Toggle("Regular expression", isOn: $searchIsRegularExpression).disabled(searchIsHex)
                    Toggle("Search backward", isOn: $searchBackwards)
                    Toggle("Whole words", isOn: $searchWholeWords).disabled(searchIsHex || searchIsRegularExpression)
                    Toggle("Case sensitive", isOn: $searchIsCaseSensitive).disabled(searchIsHex)
                }
                Button(searchBackwards ? "Find Previous" : "Find Next") { searchBackwards ? findPrevious() : findNext() }
                    .disabled(search.isEmpty || isSearching)
                    .keyboardShortcut("n", modifiers: [.control])
                if isSearching { ProgressView().controlSize(.small) }
                Text(findStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) at \(String(format: "%llX", currentOffset)) / \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(10)
        }
        .frame(minWidth: 700, minHeight: 480)
        .task { load() }
        .alert("Go To Offset", isPresented: $showingOffsetPrompt) {
            TextField("Decimal or 0x hexadecimal offset", text: $offsetText)
            Toggle("HEX", isOn: $offsetIsHex)
            Button("Go") { goToOffset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter an offset from 0 to \(fileSize) bytes.")
        }
        .sheet(isPresented: $showingImageSaveAs) {
            ImageConversionDialog(source: file)
        }
    }

    private func load() {
        do {
            fileSize = try PagedFileService.size(of: file)
            if fileSize <= 64 * 1024 * 1024, let image = NSImage(contentsOf: file), image.isValid, image.size.width > 0, image.size.height > 0 {
                imagePreview = image
                return
            }
            loadRange(at: 0)
        } catch { loadError = error.localizedDescription }
    }

    private func openSibling(by direction: Int) {
        guard siblingFiles.count > 1 else { return }
        fileIndex = (fileIndex + direction + siblingFiles.count) % siblingFiles.count
        imagePreview = nil
        imageScale = 1
        findByteCursor = 0
        loadError = nil
        load()
    }

    private func page(by direction: Int64) {
        let next = max(0, min(max(0, fileSize - 1), currentOffset + direction * windowByteCount))
        findByteCursor = next
        loadRange(at: next)
    }

    private func goToOffset() {
        let value = offsetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Int64?
        if value.lowercased().hasPrefix("0x") {
            parsed = Int64(value.dropFirst(2), radix: 16)
        } else if offsetIsHex {
            parsed = Int64(value, radix: 16)
        } else {
            parsed = Int64(value)
        }
        guard let parsed, parsed >= 0, parsed <= fileSize else {
            loadError = "Enter a valid offset between 0 and \(fileSize)."
            return
        }
        loadError = nil
        findByteCursor = parsed
        loadRange(at: parsed)
    }

    private func loadRange(at offset: Int64) {
        do {
            let safeOffset = max(0, min(offset, fileSize))
            let range = try PagedFileService.read(file, at: safeOffset, count: Int(windowByteCount))
            currentOffset = safeOffset
            data = range
            text = String(data: range, encoding: .utf8) ?? String(decoding: range, as: UTF8.self)
            findStatus = ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func findNext() { performFind(backwards: false) }

    private func findPrevious() { performFind(backwards: true) }

    private func performFind(backwards: Bool) {
        guard !search.isEmpty, !isSearching else { return }
        let pattern: FileViewerSearchPattern
        if searchIsHex {
            guard let bytes = parseHexPattern(search), !bytes.isEmpty else {
                findStatus = "Enter bytes as hexadecimal pairs or quoted text, e.g. 01 02 \"text\" 00"
                return
            }
            pattern = .bytes(bytes)
        } else if searchIsRegularExpression {
            pattern = .regularExpression(search, caseSensitive: searchIsCaseSensitive)
        } else {
            pattern = .text(search, caseSensitive: searchIsCaseSensitive, wholeWords: searchWholeWords)
        }

        let searchFile = file
        let size = fileSize
        let cursor = max(0, min(findByteCursor, size))
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let outcome: (match: FileViewerSearchMatch?, wrapped: Bool) = try await Task.detached(priority: .userInitiated) {
                    let firstRange = backwards ? 0..<cursor : cursor..<size
                    if let match = try FileViewerSearchService.find(
                        in: searchFile, fileSize: size, range: firstRange,
                        pattern: pattern, backwards: backwards
                    ) {
                        return (match: match, wrapped: false)
                    }
                    let wrapRange = backwards ? cursor..<size : 0..<cursor
                    guard let wrapped = try FileViewerSearchService.find(
                        in: searchFile, fileSize: size, range: wrapRange,
                        pattern: pattern, backwards: backwards
                    ) else { return (match: nil, wrapped: false) }
                    return (match: wrapped, wrapped: true)
                }.value

                guard let match = outcome.match else {
                    findStatus = "Text not found"
                    return
                }
                loadRange(at: match.byteOffset)
                findByteCursor = backwards ? match.byteOffset : match.byteOffset + match.byteLength
                let message = outcome.wrapped ? "Wrapped to byte" : "Found at byte"
                findStatus = String(format: "%@ %llX", message, match.byteOffset)
            } catch {
                findStatus = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    private func parseHexPattern(_ input: String) -> [UInt8]? {
        var result: [UInt8] = []
        var index = input.startIndex
        while index < input.endIndex {
            while index < input.endIndex && input[index].isWhitespace { index = input.index(after: index) }
            guard index < input.endIndex else { break }
            if input[index] == "\"" {
                index = input.index(after: index)
                var closed = false
                while index < input.endIndex {
                    if input[index] == "\"" { index = input.index(after: index); closed = true; break }
                    guard let byte = input[index].asciiValue else { return nil }
                    result.append(byte)
                    index = input.index(after: index)
                }
                guard closed else { return nil }
            } else {
                let start = index
                while index < input.endIndex && !input[index].isWhitespace { index = input.index(after: index) }
                let token = input[start..<index]
                guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
                result.append(byte)
            }
        }
        return result
    }

    private func hexDump(_ bytes: Data) -> String {
        var lines: [String] = []
        lines.reserveCapacity((bytes.count + 15) / 16)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let slice = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = slice.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }
            lines.append(String(format: "%08X  %@  %@", offset, padded, String(ascii)))
        }
        return lines.joined(separator: "\n")
    }
}
