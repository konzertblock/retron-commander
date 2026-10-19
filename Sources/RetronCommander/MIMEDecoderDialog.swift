import AppKit
import SwiftUI

struct MIMEDecoderDialog: View {
    let sourceFile: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var encoding: MIMEEncoding = .base64
    @State private var source = ""
    @State private var decoded: DecodedMIMEFile?
    @State private var messageMode = false
    @State private var attachments: [MIMEAttachment] = []
    @State private var selectedAttachmentIDs: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MIME Decoder").font(.headline)
            if let sourceFile {
                Text(sourceFile.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if messageMode {
                Table(attachments, selection: $selectedAttachmentIDs) {
                    TableColumn("Attachment") { attachment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.fileName)
                            Text(attachment.contentType).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Size") { attachment in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.decoded.data.count), countStyle: .file))
                    }.width(min: 80, ideal: 100)
                }
                .frame(minHeight: 250)
                HStack {
                    Text("\(attachments.count) attachment(s)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Selected…") { extractAttachments(attachments.filter { selectedAttachmentIDs.contains($0.id) }) }
                        .disabled(selectedAttachmentIDs.isEmpty)
                    Button("Save All…") { extractAttachments(attachments) }
                        .disabled(attachments.isEmpty)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                Picker("Encoding", selection: $encoding) {
                    ForEach(MIMEEncoding.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .overlay(alignment: .topLeading) {
                        if source.isEmpty { Text("Paste encoded message data here").foregroundStyle(.tertiary).padding(7).allowsHitTesting(false) }
                    }
                    .border(Color.gray.opacity(0.3))
                HStack {
                    Button("Decode") { decode() }.keyboardShortcut(.return, modifiers: [.command])
                    if let decoded {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(decoded.data.count), countStyle: .file)) decoded")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Decoded File…") { save(decoded) }
                    } else { Spacer() }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if let decoded {
                    Text(preview(decoded.data)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding(14)
        .frame(minWidth: 660, minHeight: 460)
        .task { await loadSource() }
    }

    private func loadSource() async {
        guard let sourceFile else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= 32 * 1024 * 1024 else { throw MIMEError.inputTooLarge }
            let data = try Data(contentsOf: sourceFile)
            let extensionName = sourceFile.pathExtension.lowercased()
            if extensionName == "eml" {
                messageMode = true
                attachments = try await Task.detached(priority: .userInitiated) {
                    try MIMEMessageParser.parse(data)
                }.value
                selectedAttachmentIDs = Set(attachments.map(\.id))
            } else {
                source = try String(contentsOf: sourceFile, encoding: .utf8)
                switch extensionName {
                case "hqx": encoding = .binHex
                case "uue": encoding = .uuencode
                case "xxe": encoding = .xxencode
                default: break
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func decode() {
        do {
            decoded = try MIDecoder.decode(source, as: encoding)
            error = nil
        } catch { decoded = nil; self.error = error.localizedDescription }
    }

    private func save(_ file: DecodedMIMEFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.suggestedFileName
            ?? sourceFile?.deletingPathExtension().lastPathComponent
            ?? "decoded.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try file.write(to: url) }
        catch { self.error = error.localizedDescription }
    }

    private func extractAttachments(_ files: [MIMEAttachment]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Attachments"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            _ = try MIMEAttachmentExportService.export(files, to: directory)
            error = nil
        } catch let failure { error = failure.localizedDescription }
    }

    private func preview(_ data: Data) -> String {
        let snippet = data.prefix(160)
        if let text = String(data: snippet, encoding: .utf8), text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            return "Preview: " + text.replacingOccurrences(of: "\n", with: " ↵ ")
        }
        return "Hex: " + snippet.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
