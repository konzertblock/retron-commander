import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PropertyListEditorDialog: View {
    let source: URL
    @Environment(\.dismiss) private var dismiss
    @State private var xml = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Property List Editor").font(.headline)
                    Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Save As…", action: saveAs)
                    .disabled(isLoading || xml.isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
            }
            Text("Binary property lists are converted to editable XML. Saving validates the complete document before writing a .plist file.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $xml)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 680, minHeight: 440)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .disabled(isLoading)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .task { load() }
    }

    private func load() {
        defer { isLoading = false }
        do {
            let data = try Data(contentsOf: source)
            var inputFormat = PropertyListSerialization.PropertyListFormat.binary
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: &inputFormat)
            let xmlData = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
            guard let text = String(data: xmlData, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            xml = text
            errorMessage = nil
        } catch {
            errorMessage = "Could not read property list: \(error.localizedDescription)"
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save Property List"
        panel.nameFieldStringValue = source.lastPathComponent
        panel.allowedContentTypes = [.propertyList]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard let xmlData = xml.data(using: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            var format = PropertyListSerialization.PropertyListFormat.xml
            let object = try PropertyListSerialization.propertyList(from: xmlData, options: [], format: &format)
            let outputFormat: PropertyListSerialization.PropertyListFormat = destination.pathExtension.lowercased() == "binary" ? .binary : .xml
            let validated = try PropertyListSerialization.data(fromPropertyList: object, format: outputFormat, options: 0)
            try validated.write(to: destination, options: .atomic)
            errorMessage = "Saved validated property list to \(destination.path)"
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
