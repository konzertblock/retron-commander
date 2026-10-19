import AppKit
import SwiftUI

private struct DBFField: Identifiable {
    let id: Int
    let name: String
    let type: Character
    let length: Int
    let decimals: Int
}

private struct DBFRecord: Identifiable, Hashable {
    let id: Int
    let deleted: Bool
    let values: [String]
}

private struct DBFTableData {
    let version: UInt8
    let recordCount: Int
    let modified: String
    let fields: [DBFField]
    let records: [DBFRecord]
    let truncated: Bool
}

private enum DBFError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

private enum DBFParser {
    static func parse(_ data: Data) throws -> DBFTableData {
        let bytes = Array(data)
        guard bytes.count >= 33 else { throw DBFError.invalid("The file is too short to contain a DBF header.") }
        let version = bytes[0]
        let count = Int(u32(bytes, 4))
        let date = "\(2000 + Int(bytes[1]))-\(String(format: "%02d", bytes[2]))-\(String(format: "%02d", bytes[3]))"
        let headerLength = Int(u16(bytes, 8))
        let recordLength = Int(u16(bytes, 10))
        guard headerLength >= 33, headerLength <= bytes.count, recordLength >= 1 else {
            throw DBFError.invalid("The DBF header or record length is invalid.")
        }
        var fields: [DBFField] = []
        var offset = 32
        var fieldIndex = 0
        while offset < headerLength, bytes[offset] != 0x0D {
            guard offset + 32 <= bytes.count else { throw DBFError.invalid("The DBF field descriptor table is truncated.") }
            let nameBytes = bytes[offset..<(offset + 11)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let type = Character(UnicodeScalar(bytes[offset + 11]))
            let length = Int(bytes[offset + 16])
            let decimals = Int(bytes[offset + 17])
            guard length > 0, !name.isEmpty else { throw DBFError.invalid("A DBF field descriptor is invalid.") }
            fields.append(DBFField(id: fieldIndex, name: name, type: type, length: length, decimals: decimals))
            fieldIndex += 1
            offset += 32
        }
        guard !fields.isEmpty, fields.reduce(1, { $0 + $1.length }) <= recordLength else {
            throw DBFError.invalid("The DBF fields do not fit in the declared record size.")
        }
        let availableCount = max(0, (bytes.count - headerLength) / recordLength)
        let rowCount = min(count, availableCount, 100_000)
        var records: [DBFRecord] = []
        records.reserveCapacity(rowCount)
        for recordIndex in 0..<rowCount {
            let base = headerLength + recordIndex * recordLength
            var cursor = base + 1
            var values: [String] = []
            values.reserveCapacity(fields.count)
            for field in fields {
                guard cursor + field.length <= base + recordLength, cursor + field.length <= bytes.count else {
                    throw DBFError.invalid("DBF record \(recordIndex + 1) is truncated.")
                }
                values.append(decodeField(Array(bytes[cursor..<(cursor + field.length)]), field: field))
                cursor += field.length
            }
            records.append(DBFRecord(id: recordIndex + 1, deleted: bytes[base] == 0x2A, values: values))
        }
        return DBFTableData(version: version, recordCount: count, modified: date, fields: fields, records: records,
                            truncated: rowCount < count || count > 100_000)
    }

    private static func decodeField(_ bytes: [UInt8], field: DBFField) -> String {
        switch field.type {
        case "I":
            guard bytes.count >= 4 else { return "" }
            return String(Int32(bitPattern: u32(bytes, 0)))
        case "Y":
            guard bytes.count >= 8 else { return "" }
            let raw = Int64(bitPattern: u64(bytes, 0))
            return String(format: "%.4f", Double(raw) / 10_000)
        case "B":
            guard bytes.count >= 8 else { return "" }
            let number = Double(bitPattern: u64(bytes, 0))
            return number.isFinite ? String(number) : ""
        case "L":
            switch bytes.first?.uppercasedASCII {
            case 0x54, 0x59: return "true"
            case 0x46, 0x4E: return "false"
            default: return "?"
            }
        case "M": return "<memo>"
        default:
            let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if field.type == "D", value.count == 8 {
                return "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.suffix(2))"
            }
            return value
        }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}

private extension UInt8 {
    var uppercasedASCII: UInt8 { (0x61...0x7A).contains(self) ? self - 32 : self }
}

struct DBFViewerDialog: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var table: DBFTableData?
    @State private var error: String?
    @State private var search = ""
    @State private var selected: Set<Int> = []
    @State private var bookmarks: Set<Int> = []
    @State private var showDeleted = true
    @State private var onlyBookmarks = false

    private var visibleRecords: [DBFRecord] {
        guard let table else { return [] }
        return table.records.filter { record in
            (showDeleted || !record.deleted) && (!onlyBookmarks || bookmarks.contains(record.id)) &&
            (search.isEmpty || record.values.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                if let table {
                    Text("\(table.records.count) / \(table.recordCount) records · \(table.fields.count) fields · \(table.modified)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error {
                ContentUnavailableView("Could Not Read DBF Table", systemImage: "tablecells", description: Text(error))
            } else if let table {
                HStack {
                    TextField("Search records", text: $search).textFieldStyle(.roundedBorder)
                    Toggle("Show deleted", isOn: $showDeleted).toggleStyle(.checkbox)
                    Toggle("Bookmarks only", isOn: $onlyBookmarks).toggleStyle(.checkbox).disabled(bookmarks.isEmpty)
                    Button("Bookmark") { bookmarks.formUnion(selected) }.disabled(selected.isEmpty)
                    Button("Copy TSV") { copySelected(table) }.disabled(selected.isEmpty)
                }
                if table.truncated { Text("The file has more rows than this viewer loads (limit: 100,000 rows).") .font(.caption).foregroundStyle(.orange) }
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 0) {
                            gridCell("#", width: 52, header: true)
                            ForEach(table.fields) { field in gridCell(field.name, width: columnWidth(field), header: true) }
                        }
                        ForEach(visibleRecords) { record in
                            HStack(spacing: 0) {
                                gridCell(String(record.id), width: 52)
                                ForEach(table.fields) { field in
                                    let value = record.values.indices.contains(field.id) ? record.values[field.id] : ""
                                    gridCell(value, width: columnWidth(field), deleted: record.deleted)
                                }
                            }
                            .background(selected.contains(record.id) ? Color.accentColor.opacity(0.22) : (record.deleted ? Color.red.opacity(0.07) : Color(nsColor: .textBackgroundColor)))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = selected.contains(record.id) ? selected.subtracting([record.id]) : [record.id] }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                HStack {
                    Text("DBF type 0x\(String(format: "%02X", table.version))")
                    Spacer()
                    Text("\(visibleRecords.count) displayed")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 780, minHeight: 500)
        .task { load() }
    }

    private func load() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= 64 * 1024 * 1024 else { throw DBFError.invalid("Files larger than 64 MB are not loaded into the DBF viewer.") }
            table = try DBFParser.parse(Data(contentsOf: file, options: [.mappedIfSafe]))
        } catch { self.error = error.localizedDescription }
    }

    private func copySelected(_ table: DBFTableData) {
        let chosen = table.records.filter { selected.contains($0.id) }
        let header = ["#"] + table.fields.map(\.name)
        let rows = chosen.map { [String($0.id)] + $0.values }
        let text = ([header] + rows).map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func columnWidth(_ field: DBFField) -> CGFloat { min(240, max(68, CGFloat(field.length) * 8)) }

    private func gridCell(_ value: String, width: CGFloat, header: Bool = false, deleted: Bool = false) -> some View {
        Text(value)
            .font(.system(size: 10, weight: header ? .semibold : .regular, design: header ? .default : .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .frame(width: width, height: 22, alignment: .leading)
            .background(header ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .foregroundStyle(deleted && !header ? Color.red : Color.primary)
            .overlay(alignment: .bottomTrailing) { Rectangle().fill(Color.gray.opacity(0.22)).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.18)).frame(height: 1) }
    }
}
