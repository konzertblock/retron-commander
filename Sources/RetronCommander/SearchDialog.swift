import SwiftUI

struct SearchDialog: View {
    let root: URL
    let openResult: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var namePattern = "*"
    @State private var textPattern = ""
    @State private var includeHidden = false
    @State private var searching = false
    @State private var results: [FileSearchResult] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find Files and Directories")
                .font(.system(size: 15, weight: .semibold))
            HStack {
                Text("Look in:").frame(width: 90, alignment: .trailing)
                Text(root.path).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Text("File name:").frame(width: 90, alignment: .trailing)
                TextField("*", text: $namePattern)
            }
            HStack {
                Text("Containing text:").frame(width: 90, alignment: .trailing)
                TextField("(optional)", text: $textPattern)
            }
            Toggle("Include hidden files and folders", isOn: $includeHidden)
                .padding(.leading, 96)

            Table(results) {
                TableColumn("Name") { result in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.url.lastPathComponent)
                        Text(result.url.deletingLastPathComponent().path)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Size") { result in Text(result.isDirectory ? "<DIR>" : ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file)) }
                    .width(min: 70, ideal: 90)
                TableColumn("Modified") { result in Text(result.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "") }
                    .width(min: 120, ideal: 140)
            }
            .frame(minHeight: 250)

            HStack {
                if searching { ProgressView().controlSize(.small) }
                Text(error ?? "\(results.count) result(s)")
                    .font(.system(size: 11)).foregroundStyle(error == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Search") { runSearch() }.keyboardShortcut(.defaultAction).disabled(searching)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 650, minHeight: 460)
        .onChange(of: results.count) { _, _ in error = nil }
    }

    private func runSearch() {
        searching = true
        error = nil
        let root = self.root
        let pattern = namePattern
        let content = textPattern
        let hidden = includeHidden
        Task.detached(priority: .userInitiated) {
            do {
                let found = try FileSearchEngine.search(root: root, pattern: pattern, content: content, includeHidden: hidden)
                await MainActor.run { results = found; searching = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; searching = false }
            }
        }
    }
}
