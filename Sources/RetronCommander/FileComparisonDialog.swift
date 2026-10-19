import SwiftUI

private struct ComparisonRow: Identifiable {
    let id: Int
    let leftNumber: Int?
    let leftText: String?
    let rightNumber: Int?
    let rightText: String?
    let isDifferent: Bool
}

struct FileComparisonDialog: View {
    let left: URL
    let right: URL
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ComparisonRow] = []
    @State private var message = "Comparing files…"
    @State private var error: String?
    @State private var changedRows: [Int] = []
    @State private var currentChange = 0
    @State private var isHex = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(left.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.left.arrow.right")
                Spacer()
                Text(right.lastPathComponent).font(.headline).lineLimit(1)
            }
            .padding(12)
            HStack(spacing: 0) {
                Text("Line").frame(width: 54, alignment: .trailing).padding(.trailing, 6)
                Text(left.path).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                Divider()
                Text("Line").frame(width: 54, alignment: .trailing).padding(.trailing, 6)
                Text(right.path).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 0) {
                                lineNumber(row.leftNumber)
                                lineText(row.leftText, different: row.isDifferent)
                                Divider()
                                lineNumber(row.rightNumber)
                                lineText(row.rightText, different: row.isDifferent)
                            }
                            .id(row.id)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: currentChange) { _, value in
                    guard changedRows.indices.contains(value) else { return }
                    withAnimation { proxy.scrollTo(changedRows[value], anchor: .center) }
                }
            }
            HStack(spacing: 10) {
                if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
                else { Text(message).lineLimit(1) }
                Spacer()
                if !changedRows.isEmpty {
                    Button("Previous Difference") { currentChange = (currentChange - 1 + changedRows.count) % changedRows.count }
                    Button("Next Difference") { currentChange = (currentChange + 1) % changedRows.count }
                }
                Button("Copy Right Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(right.path, forType: .string)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 11)).padding(10)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { compare() }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 54, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private func lineText(_ text: String?, different: Bool) -> some View {
        Text(text ?? "")
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(different ? Color.orange.opacity(0.16) : Color.clear)
    }

    private func compare() {
        do {
            let leftAttributes = try FileManager.default.attributesOfItem(atPath: left.path)
            let rightAttributes = try FileManager.default.attributesOfItem(atPath: right.path)
            let limit = Int64(64 * 1024 * 1024)
            let leftSize = (leftAttributes[.size] as? NSNumber)?.int64Value ?? 0
            let rightSize = (rightAttributes[.size] as? NSNumber)?.int64Value ?? 0
            if leftSize > limit || rightSize > limit { throw ComparisonError.tooLarge }
            let leftData = try Data(contentsOf: left, options: [.mappedIfSafe])
            let rightData = try Data(contentsOf: right, options: [.mappedIfSafe])
            if let leftText = String(data: leftData, encoding: .utf8), let rightText = String(data: rightData, encoding: .utf8) {
                rows = Self.align(leftText.components(separatedBy: .newlines), rightText.components(separatedBy: .newlines))
                isHex = false
            } else {
                rows = Self.align(Self.hexLines(leftData), Self.hexLines(rightData))
                isHex = true
            }
            changedRows = rows.filter(\.isDifferent).map(\.id)
            let firstOffset = zip(leftData, rightData).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
            if leftData == rightData { message = "Files are identical (\(leftData.count) bytes)." }
            else {
                let offset = firstOffset ?? min(leftData.count, rightData.count)
                let mode = isHex ? "Hex" : "Text"
                message = "\(mode) comparison · \(changedRows.count) differing row(s) · first byte difference at \(offset) · \(leftData.count) / \(rightData.count) bytes"
            }
        } catch { self.error = error.localizedDescription }
    }

    private static func align(_ left: [String], _ right: [String]) -> [ComparisonRow] {
        var result: [ComparisonRow] = []
        var i = 0, j = 0
        let lookahead = 32
        while i < left.count || j < right.count {
            if i < left.count, j < right.count, left[i] == right[j] {
                result.append(ComparisonRow(id: result.count, leftNumber: i + 1, leftText: left[i], rightNumber: j + 1, rightText: right[j], isDifferent: false))
                i += 1; j += 1
                continue
            }
            let rightSearchLimit = min(lookahead, max(0, right.count - j - 1))
            let leftSearchLimit = min(lookahead, max(0, left.count - i - 1))
            let leftMatchInRight = i < left.count && rightSearchLimit > 0
                ? (1...rightSearchLimit).first(where: { right[j + $0] == left[i] }) : nil
            let rightMatchInLeft = j < right.count && leftSearchLimit > 0
                ? (1...leftSearchLimit).first(where: { left[i + $0] == right[j] }) : nil
            if let distance = leftMatchInRight, rightMatchInLeft == nil || distance < rightMatchInLeft! {
                for _ in 0..<distance {
                    result.append(ComparisonRow(id: result.count, leftNumber: nil, leftText: nil, rightNumber: j + 1, rightText: right[j], isDifferent: true))
                    j += 1
                }
            } else if let distance = rightMatchInLeft {
                for _ in 0..<distance {
                    result.append(ComparisonRow(id: result.count, leftNumber: i + 1, leftText: left[i], rightNumber: nil, rightText: nil, isDifferent: true))
                    i += 1
                }
            } else if i < left.count && j < right.count {
                result.append(ComparisonRow(id: result.count, leftNumber: i + 1, leftText: left[i], rightNumber: j + 1, rightText: right[j], isDifferent: true))
                i += 1; j += 1
            } else if i < left.count {
                result.append(ComparisonRow(id: result.count, leftNumber: i + 1, leftText: left[i], rightNumber: nil, rightText: nil, isDifferent: true))
                i += 1
            } else if j < right.count {
                result.append(ComparisonRow(id: result.count, leftNumber: nil, leftText: nil, rightNumber: j + 1, rightText: right[j], isDifferent: true))
                j += 1
            }
        }
        return result
    }

    private static func hexLines(_ data: Data) -> [String] {
        stride(from: 0, to: data.count, by: 16).map { offset in
            let end = min(offset + 16, data.count)
            let bytes = data[offset..<end]
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let text = bytes.map { byte -> Character in
                byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "."
            }
            return String(format: "%08X  %@  %@", offset, hex, String(text))
        }
    }
}

private enum ComparisonError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "The internal comparison view is limited to 64 MB per file." }
}
