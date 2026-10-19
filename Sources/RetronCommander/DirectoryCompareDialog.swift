import SwiftUI

struct DirectoryCompareDialog: View {
    let left: URL
    let right: URL

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [DirectoryCompareEntry] = []
    @State private var error: String?

    private var differenceCount: Int { rows.filter { $0.result != .same }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare Directories").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Text(left.path).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Text(right.path).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 10, design: .monospaced))
            Table(rows) {
                TableColumn("Name", value: \.name)
                TableColumn("Left size") { row in Text(size(row.leftSize, directory: row.isDirectory)) }.width(min: 75, ideal: 90)
                TableColumn("Right size") { row in Text(size(row.rightSize, directory: row.isDirectory)) }.width(min: 75, ideal: 90)
                TableColumn("Result") { row in Text(row.result.rawValue) }.width(min: 85, ideal: 100)
            }
            .frame(minHeight: 300)
            Text(error ?? "\(rows.count) names · \(differenceCount) differences · folder contents are not recursed")
                .font(.system(size: 10)).foregroundStyle(error == nil ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("Refresh") { load() }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 420)
        .onAppear(perform: load)
    }

    private func load() {
        do { rows = try DirectoryCompareEngine.compare(left: left, right: right); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func size(_ size: Int64?, directory: Bool) -> String {
        if directory { return "<DIR>" }
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
