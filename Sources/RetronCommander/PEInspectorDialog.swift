import Foundation
import SwiftUI

struct PESection: Identifiable {
    let id: Int
    let name: String
    let virtualAddress: UInt32
    let virtualSize: UInt32
    let fileOffset: UInt32
    let fileSize: UInt32
    let characteristics: UInt32
}

struct PEDebugEntry: Identifiable {
    let id: Int
    let type: String
    let timestamp: String
    let size: String
    let details: String
}

struct PEResource: Identifiable {
    let id: String
    let type: String
    let name: String
    let language: String
    let size: String
    let rva: String
}

struct PEInspection {
    let machine: String
    let bitness: String
    let timestamp: String
    let entryPoint: String
    let imageBase: String
    let subsystem: String
    let sections: [PESection]
    let imports: [String]
    let exports: [String]
    let debugEntries: [PEDebugEntry]
    let resources: [PEResource]
}

enum PEInspectionError: LocalizedError {
    case truncated
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .truncated: "The file ends before the PE structures are complete."
        case .invalid(let reason): reason
        }
    }
}

struct PEParser {
    let data: Data
    let bytes: [UInt8]

    init(data: Data) { self.data = data; bytes = Array(data) }

    func inspect() throws -> PEInspection {
        guard bytes.count >= 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { throw PEInspectionError.invalid("The file does not have an MZ executable header.") }
        let peOffset = Int(try u32(0x3C))
        guard try u32(peOffset) == 0x00004550 else { throw PEInspectionError.invalid("The DOS header does not point to a PE signature.") }
        let coff = peOffset + 4
        let machineValue = try u16(coff)
        let sectionCount = Int(try u16(coff + 2))
        let timestampValue = try u32(coff + 4)
        let optionalSize = Int(try u16(coff + 16))
        let optional = coff + 20
        let magic = try u16(optional)
        let is64 = magic == 0x20B
        guard magic == 0x10B || is64 else { throw PEInspectionError.invalid("Unsupported PE optional-header magic 0x\(String(magic, radix: 16)).") }
        let entry = try u32(optional + 16)
        let imageBase = is64 ? try u64(optional + 24) : UInt64(try u32(optional + 28))
        let subsystemValue = try u16(optional + 68)
        let directoryStart = optional + (is64 ? 112 : 96)
        let directoryCountOffset = optional + (is64 ? 108 : 92)
        let directoryCount = min(Int(try u32(directoryCountOffset)), 16)
        guard sectionCount <= 4096, optional + optionalSize <= bytes.count else { throw PEInspectionError.truncated }
        let sectionStart = optional + optionalSize
        guard sectionStart + sectionCount * 40 <= bytes.count else { throw PEInspectionError.truncated }
        var sections: [PESection] = []
        for index in 0..<sectionCount {
            let base = sectionStart + index * 40
            sections.append(PESection(
                id: index,
                name: cString(base, maxLength: 8),
                virtualAddress: try u32(base + 12),
                virtualSize: try u32(base + 8),
                fileOffset: try u32(base + 20),
                fileSize: try u32(base + 16),
                characteristics: try u32(base + 36)
            ))
        }
        let importDirectory = directoryCount > 1 ? (try? (u32(directoryStart + 8), u32(directoryStart + 12))) : nil
        let exportDirectory = directoryCount > 0 ? (try? (u32(directoryStart), u32(directoryStart + 4))) : nil
        let resourceDirectory = directoryCount > 2 ? (try? (u32(directoryStart + 16), u32(directoryStart + 20))) : nil
        let debugDirectory = directoryCount > 6 ? (try? (u32(directoryStart + 48), u32(directoryStart + 52))) : nil
        let headersSize = Int(try u32(optional + 60))
        return PEInspection(
            machine: machineName(machineValue),
            bitness: is64 ? "PE32+ (64-bit)" : "PE32 (32-bit)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestampValue)).formatted(date: .abbreviated, time: .standard),
            entryPoint: String(format: "0x%08X", entry),
            imageBase: String(format: "0x%llX", imageBase),
            subsystem: subsystemName(subsystemValue),
            sections: sections,
            imports: importDirectory.flatMap { try? parseImports(rva: $0.0, size: $0.1, sections: sections, headersSize: headersSize) } ?? [],
            exports: exportDirectory.flatMap { try? parseExports(rva: $0.0, size: $0.1, sections: sections, headersSize: headersSize) } ?? [],
            debugEntries: debugDirectory.flatMap { try? parseDebug(rva: $0.0, size: $0.1, sections: sections, headersSize: headersSize) } ?? [],
            resources: resourceDirectory.flatMap { try? parseResources(rva: $0.0, size: $0.1, sections: sections, headersSize: headersSize) } ?? []
        )
    }

    private func parseDebug(rva: UInt32, size: UInt32, sections: [PESection], headersSize: Int) throws -> [PEDebugEntry] {
        guard rva != 0, let start = fileOffset(rva, sections: sections, headersSize: headersSize) else { return [] }
        let count = min(Int(size) / 28, 4096)
        return (0..<count).compactMap { index in
            let offset = start + index * 28
            guard offset + 28 <= bytes.count,
                  let timestampValue = try? u32(offset + 4),
                  let typeValue = try? u32(offset + 12),
                  let dataSize = try? u32(offset + 16),
                  let dataRVA = try? u32(offset + 20),
                  let rawOffset = try? u32(offset + 24) else { return nil }
            let dataOffset = rawOffset != 0 && UInt64(rawOffset) + UInt64(dataSize) <= UInt64(bytes.count)
                ? Int(rawOffset)
                : fileOffset(dataRVA, sections: sections, headersSize: headersSize)
            let details = dataOffset.map { debugDetails(type: typeValue, offset: $0, size: Int(dataSize)) } ?? ""
            return PEDebugEntry(
                id: index,
                type: debugType(typeValue),
                timestamp: timestampValue == 0 ? "—" : Date(timeIntervalSince1970: TimeInterval(timestampValue)).formatted(date: .abbreviated, time: .shortened),
                size: ByteCountFormatter.string(fromByteCount: Int64(dataSize), countStyle: .file),
                details: details
            )
        }
    }

    private func debugDetails(type: UInt32, offset: Int, size: Int) -> String {
        guard size > 0, offset >= 0, offset < bytes.count else { return "" }
        let end = min(bytes.count, offset + size)
        if type == 2, size >= 24, cString(offset, maxLength: 4) == "RSDS" {
            let guid = bytes[(offset + 4)..<(offset + 20)].map { String(format: "%02X", $0) }.joined()
            let age = (try? u32(offset + 20)).map(String.init) ?? "?"
            let path = cString(offset + 24, maxLength: max(0, end - offset - 24))
            return "PDB: \(path) · GUID \(guid) · age \(age)"
        }
        if type == 4, size >= 12, (try? u32(offset)) == 1 {
            let path = cString(offset + 12, maxLength: max(0, end - offset - 12))
            return path.isEmpty ? "MISC debug record" : path
        }
        return ""
    }

    private func parseResources(rva: UInt32, size: UInt32, sections: [PESection], headersSize: Int) throws -> [PEResource] {
        guard rva != 0, size >= 16, let rootOffset = fileOffset(rva, sections: sections, headersSize: headersSize) else { return [] }
        let rootRVA = rva
        var output: [PEResource] = []
        func walk(_ relativeOffset: UInt32, depth: Int, labels: [String]) {
            guard depth <= 2, output.count < 20_000,
                  relativeOffset < size,
                  UInt64(rootRVA) + UInt64(relativeOffset) <= UInt64(UInt32.max),
                  let directoryOffset = fileOffset(rootRVA + relativeOffset, sections: sections, headersSize: headersSize),
                  directoryOffset + 16 <= bytes.count else { return }
            let namedCount = Int((try? u16(directoryOffset + 12)) ?? 0)
            let idCount = Int((try? u16(directoryOffset + 14)) ?? 0)
            let count = min(namedCount + idCount, 4096)
            for index in 0..<count {
                let entry = directoryOffset + 16 + index * 8
                guard entry + 8 <= bytes.count,
                      let rawName = try? u32(entry),
                      let rawTarget = try? u32(entry + 4) else { continue }
                let label = resourceLabel(rawName, rootOffset: rootOffset)
                let nextLabels = labels + [label]
                if rawTarget & 0x80000000 != 0 {
                    walk(rawTarget & 0x7FFFFFFF, depth: depth + 1, labels: nextLabels)
                } else if depth == 2 {
                    guard UInt64(rootRVA) + UInt64(rawTarget & 0x7FFFFFFF) <= UInt64(UInt32.max) else { continue }
                    let dataEntryRVA = rootRVA + (rawTarget & 0x7FFFFFFF)
                    guard let dataEntry = fileOffset(dataEntryRVA, sections: sections, headersSize: headersSize),
                          dataEntry + 16 <= bytes.count,
                          let payloadRVA = try? u32(dataEntry),
                          let payloadSize = try? u32(dataEntry + 4) else { continue }
                    output.append(PEResource(
                        id: "\(output.count):\(nextLabels.joined(separator: "/"))",
                        type: nextLabels.first ?? "?",
                        name: nextLabels.dropFirst().first ?? "?",
                        language: nextLabels.dropFirst(2).first ?? "?",
                        size: ByteCountFormatter.string(fromByteCount: Int64(payloadSize), countStyle: .file),
                        rva: String(format: "0x%08X", payloadRVA)
                    ))
                }
            }
        }
        walk(0, depth: 0, labels: [])
        return output
    }

    private func resourceLabel(_ value: UInt32, rootOffset: Int) -> String {
        if value & 0x80000000 == 0 {
            let id = value & 0xFFFF
            if rootOffset >= 0 { return resourceIDName(id) ?? "ID \(id)" }
            return "ID \(id)"
        }
        let relative = Int(value & 0x7FFFFFFF)
        let offset = rootOffset + relative
        guard let length = try? u16(offset), length <= 2048, offset + 2 + Int(length) * 2 <= bytes.count else { return "<invalid name>" }
        let units = (0..<Int(length)).compactMap { try? u16(offset + 2 + $0 * 2) }
        return String(decoding: units, as: UTF16.self)
    }

    private func resourceIDName(_ value: UInt32) -> String? {
        switch value {
        case 1: "CURSOR"; case 2: "BITMAP"; case 3: "ICON"; case 4: "MENU"; case 5: "DIALOG"
        case 6: "STRING"; case 7: "FONTDIR"; case 8: "FONT"; case 9: "ACCELERATOR"; case 10: "RCDATA"
        case 11: "MESSAGETABLE"; case 12: "GROUP_CURSOR"; case 14: "GROUP_ICON"; case 16: "VERSION"
        case 17: "DLGINCLUDE"; case 19: "PLUGPLAY"; case 20: "VXD"; case 21: "ANICURSOR"
        case 22: "ANIICON"; case 23: "HTML"; case 24: "MANIFEST"; default: nil
        }
    }

    private func debugType(_ value: UInt32) -> String {
        switch value {
        case 1: "COFF"; case 2: "CodeView"; case 3: "FPO"; case 4: "MISC"
        case 5: "Exception"; case 6: "Fixup"; case 7: "OMAP to source"; case 8: "OMAP from source"
        case 9: "Borland"; case 10: "Reserved10"; case 11: "CLSID"; case 12: "VC feature"
        case 13: "PGO"; case 14: "ILTCG"; case 16: "Reproducible"; case 17: "Embedded Portable PDB"
        case 19: "PDB checksum"; case 20: "Extended DLL characteristics"; default: "Type \(value)"
        }
    }

    private func parseImports(rva: UInt32, size: UInt32, sections: [PESection], headersSize: Int) throws -> [String] {
        guard rva != 0, let start = fileOffset(rva, sections: sections, headersSize: headersSize) else { return [] }
        let maxCount = min(Int(size) / 20, 10000)
        var values: [String] = []
        for index in 0..<maxCount {
            let offset = start + index * 20
            guard let nameRVA = try? u32(offset + 12), nameRVA != 0 else { break }
            if let nameOffset = fileOffset(nameRVA, sections: sections, headersSize: headersSize) {
                let name = cString(nameOffset, maxLength: 512)
                if !name.isEmpty { values.append(name) }
            }
        }
        return values
    }

    private func parseExports(rva: UInt32, size: UInt32, sections: [PESection], headersSize: Int) throws -> [String] {
        guard rva != 0, size >= 40, let start = fileOffset(rva, sections: sections, headersSize: headersSize) else { return [] }
        let count = min(Int(try u32(start + 24)), 20000)
        let namesRVA = try u32(start + 32)
        guard let namesOffset = fileOffset(namesRVA, sections: sections, headersSize: headersSize) else { return [] }
        var values: [String] = []
        for index in 0..<count {
            guard let nameRVA = try? u32(namesOffset + index * 4), let nameOffset = fileOffset(nameRVA, sections: sections, headersSize: headersSize) else { continue }
            let name = cString(nameOffset, maxLength: 2048)
            if !name.isEmpty { values.append(name) }
        }
        return values
    }

    private func fileOffset(_ rva: UInt32, sections: [PESection], headersSize: Int) -> Int? {
        if Int(rva) < headersSize, Int(rva) < bytes.count { return Int(rva) }
        for section in sections {
            let span = max(section.virtualSize, section.fileSize)
            guard rva >= section.virtualAddress, rva - section.virtualAddress < span else { continue }
            let offset = UInt64(section.fileOffset) + UInt64(rva - section.virtualAddress)
            guard offset < UInt64(bytes.count) else { return nil }
            return Int(offset)
        }
        return nil
    }

    private func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw PEInspectionError.truncated }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw PEInspectionError.truncated }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func u64(_ offset: Int) throws -> UInt64 {
        let low = UInt64(try u32(offset))
        let high = UInt64(try u32(offset + 4))
        return low | high << 32
    }

    private func cString(_ offset: Int, maxLength: Int) -> String {
        guard offset >= 0, offset < bytes.count else { return "" }
        let end = min(bytes.count, offset + maxLength)
        let terminator = bytes[offset..<end].firstIndex(of: 0) ?? end
        return String(decoding: bytes[offset..<terminator], as: UTF8.self)
    }

    private func machineName(_ value: UInt16) -> String {
        let name: String
        switch value {
        case 0x014C: name = "Intel 386"
        case 0x8664: name = "AMD64 / x86-64"
        case 0x01C0: name = "ARM"
        case 0x01C4: name = "ARMv7"
        case 0xAA64: name = "ARM64"
        default: name = "Unknown"
        }
        return "\(name) (0x\(String(value, radix: 16).uppercased()))"
    }

    private func subsystemName(_ value: UInt16) -> String {
        switch value {
        case 1: "Native"
        case 2: "Windows GUI"
        case 3: "Windows console"
        case 7: "POSIX console"
        case 9: "Windows CE GUI"
        case 10: "EFI application"
        case 14: "Xbox"
        default: "Unknown (\(value))"
        }
    }
}

struct PEInspectorDialog: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: PEInspection?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(file.lastPathComponent).font(.headline); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let error {
                ContentUnavailableView("Could Not Inspect Executable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let inspection {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    infoRow("Machine", inspection.machine)
                    infoRow("Format", inspection.bitness)
                    infoRow("Link timestamp", inspection.timestamp)
                    infoRow("Entry point", inspection.entryPoint)
                    infoRow("Image base", inspection.imageBase)
                    infoRow("Subsystem", inspection.subsystem)
                }
                TabView {
                    Table(inspection.sections) {
                        TableColumn("Name", value: \.name)
                        TableColumn("Virtual size") { Text(String(format: "%08X", $0.virtualSize)) }
                        TableColumn("RVA") { Text(String(format: "%08X", $0.virtualAddress)) }
                        TableColumn("File size") { Text(String(format: "%08X", $0.fileSize)) }
                        TableColumn("Flags") { Text(String(format: "%08X", $0.characteristics)) }
                    }.tabItem { Text("Sections (\(inspection.sections.count))") }
                    nameList(inspection.imports).tabItem { Text("Imports (\(inspection.imports.count))") }
                    nameList(inspection.exports).tabItem { Text("Exports (\(inspection.exports.count))") }
                    Table(inspection.debugEntries) {
                        TableColumn("Type", value: \.type)
                        TableColumn("Timestamp", value: \.timestamp)
                        TableColumn("Size", value: \.size)
                        TableColumn("Details", value: \.details)
                    }.tabItem { Text("Debug (\(inspection.debugEntries.count))") }
                    Table(inspection.resources) {
                        TableColumn("Type", value: \.type)
                        TableColumn("Name", value: \.name)
                        TableColumn("Language", value: \.language)
                        TableColumn("Size", value: \.size)
                        TableColumn("Data RVA", value: \.rva)
                    }.tabItem { Text("Resources (\(inspection.resources.count))") }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 740, minHeight: 500)
        .task { load() }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).font(.system(.body, design: .monospaced)) }
    }

    private func nameList(_ values: [String]) -> some View {
        List(values, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
    }

    private func load() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= 256 * 1024 * 1024 else { throw PEInspectionError.invalid("Files larger than 256 MB are not loaded into the PE inspector.") }
            inspection = try PEParser(data: Data(contentsOf: file, options: [.mappedIfSafe])).inspect()
        } catch { self.error = error.localizedDescription }
    }
}
