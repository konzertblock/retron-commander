import AppKit
import SwiftUI

struct BatchRenameDialog: View {
    private let selectedEntries: [FileEntry]
    @State private var entries: [FileEntry]
    let root: URL
    let rename: ([FileEntry], [String], BatchRenameTemplate.PathMode, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nameTemplate = "$(OriginalName)"
    @State private var pathMode: BatchRenameTemplate.PathMode = .fileName
    @State private var find = ""
    @State private var replacement = ""
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var numberStart = ""
    @State private var useRegularExpression = false
    @State private var caseSensitive = false
    @State private var replaceOnlyOnce = false
    @State private var wholeWords = false
    @State private var excludeExtension = true
    @State private var nameCase = "unchanged"
    @State private var extensionCase = "unchanged"
    @State private var includePathInCase = false
    @State private var manualMode = false
    @State private var manualNames: [String] = []
    @State private var includeSubdirectories = false
    @State private var removeEmptiedDirectories = false
    @State private var fileMask = "*"
    @State private var error: String?

    init(entries: [FileEntry], root: URL, rename: @escaping ([FileEntry], [String], BatchRenameTemplate.PathMode, Bool) throws -> Void) {
        selectedEntries = entries
        _entries = State(initialValue: entries)
        self.root = root
        self.rename = rename
    }

    private var proposed: [String] {
        entries.enumerated().map { index, entry in
            var name = BatchRenameTemplate.expand(nameTemplate, item: .init(url: entry.url, name: entry.name, isDirectory: entry.isDirectory, byteSize: entry.byteSize, modifiedAt: entry.modifiedAt), index: index, root: root, pathMode: pathMode)
            let initialSplit = splitPath(name)
            var pathPrefix = pathMode == .fileName ? "" : initialSplit.prefix
            let nameComponent = initialSplit.component
            var stem = entry.isDirectory ? nameComponent : URL(fileURLWithPath: nameComponent).deletingPathExtension().lastPathComponent
            var ext = entry.isDirectory ? "" : URL(fileURLWithPath: nameComponent).pathExtension
            if !find.isEmpty {
                let target = pathPrefix + stem + (excludeExtension || ext.isEmpty ? "" : "." + ext)
                let replaced = replace(in: target)
                (pathPrefix, name) = splitPath(replaced)
                stem = entry.isDirectory || excludeExtension ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                if !excludeExtension { ext = entry.isDirectory ? "" : URL(fileURLWithPath: name).pathExtension }
            }
            stem = prefix + stem + suffix
            if let first = Int(numberStart) { stem += String(format: "%03d", first + index) }
            pathPrefix = includePathInCase ? transformCase(pathPrefix, mode: nameCase) : pathPrefix
            stem = transformCase(stem, mode: nameCase)
            ext = transformCase(ext, mode: extensionCase)
            return pathPrefix + (ext.isEmpty ? stem : stem + "." + ext)
        }
    }

    private var currentNames: [String] { manualMode ? manualNames : proposed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch Rename").font(.headline)
            HStack {
                Text("New name template")
                TextField("$(OriginalName)", text: $nameTemplate)
                    .font(.system(.body, design: .monospaced))
            }
            Picker("Rename", selection: $pathMode) {
                ForEach(BatchRenameTemplate.PathMode.allCases) { mode in Text(mode.label).tag(mode) }
            }.pickerStyle(.segmented)
            Text("Variables: OriginalName, Drive, Path, RelativePath, Name, NamePart, ExtPart, Size, Date:format, Time:format, Counter:start,step,base,width,fill")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                TextField("File mask", text: $fileMask)
                    .onChange(of: fileMask) { _, _ in refreshEntries() }
                Toggle("Include subdirectories", isOn: $includeSubdirectories)
                    .onChange(of: includeSubdirectories) { _, _ in refreshEntries() }
                    .disabled(selectedEntries.contains(where: { $0.archiveURL != nil }))
                Toggle("Remove emptied directories", isOn: $removeEmptiedDirectories)
                    .disabled(pathMode == .fileName)
            }
            HStack {
                TextField(useRegularExpression ? "Regular expression" : "Find in name", text: $find)
                TextField(useRegularExpression ? "Replacement template ($1, $2…)" : "Replace with", text: $replacement)
            }
            Toggle("Use regular expressions", isOn: $useRegularExpression).toggleStyle(.checkbox)
            HStack {
                Toggle("Case sensitive", isOn: $caseSensitive)
                Toggle("Only once per name", isOn: $replaceOnlyOnce)
                Toggle("Whole words", isOn: $wholeWords)
                Toggle("Exclude extension", isOn: $excludeExtension)
            }.toggleStyle(.checkbox).font(.system(size: 11))
            Toggle("Manual mode", isOn: $manualMode).toggleStyle(.checkbox)
                .onChange(of: manualMode) { _, enabled in manualNames = enabled ? proposed : [] }
            if manualMode {
                HStack {
                    Button("Copy name list") { copyNames() }
                    Button("Paste name list") { pasteNames() }
                }
            }
            HStack {
                TextField("Prefix", text: $prefix)
                TextField("Suffix", text: $suffix)
                TextField("Start numbering (optional)", text: $numberStart).frame(width: 180)
            }
            HStack {
                Picker("Filename case", selection: $nameCase) {
                    Text("Keep").tag("unchanged"); Text("lower").tag("lower"); Text("UPPER").tag("upper"); Text("Mixed").tag("mixed")
                }
                Picker("Extension case", selection: $extensionCase) {
                    Text("Keep").tag("unchanged"); Text("lower").tag("lower"); Text("UPPER").tag("upper"); Text("Mixed").tag("mixed")
                }
                Toggle("Include path in case conversion", isOn: $includePathInCase).toggleStyle(.checkbox)
            }.pickerStyle(.menu)
            Table(previewRows) {
                TableColumn("Current name", value: \.original)
                TableColumn("New name") { row in
                    if manualMode, manualNames.indices.contains(row.id) {
                        TextField("New name", text: $manualNames[row.id]).textFieldStyle(.plain)
                    } else { Text(row.proposed) }
                }
                TableColumn("Size", value: \.size)
                TableColumn("Modified", value: \.modified)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text("\(entries.count) items").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }.keyboardShortcut(.defaultAction)
                    .disabled(entries.isEmpty || unchanged)
            }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 530)
    }

    private func commit() {
        if useRegularExpression && !find.isEmpty && (try? NSRegularExpression(pattern: find)) == nil {
            error = "The regular expression is invalid."
            return
        }
        guard currentNames.count == entries.count else { error = "The manual list must contain one name for every selected item."; return }
        do { try rename(entries, currentNames, pathMode, removeEmptiedDirectories && pathMode != .fileName); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private var previewRows: [RenamePreview] {
        Array(zip(entries, currentNames).enumerated()).map { index, pair in
            RenamePreview(id: index, original: previewName(pair.0), proposed: pair.1,
                          size: pair.0.isDirectory ? "<DIR>" : ByteCountFormatter.string(fromByteCount: pair.0.byteSize, countStyle: .file),
                          modified: pair.0.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "")
        }
    }

    private var unchanged: Bool {
        zip(entries, currentNames).allSatisfy { pair in originalValue(pair.0) == pair.1 }
    }

    private func copyNames() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manualNames.joined(separator: "\n"), forType: .string)
    }

    private func pasteNames() {
        guard let text = NSPasteboard.general.string(forType: .string) else { error = "The clipboard does not contain a name list."; return }
        var names = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .newlines) }
        if names.last == "", text.last?.isNewline == true { names.removeLast() }
        guard names.count == entries.count else {
            error = "The clipboard contains \(names.count) names for \(entries.count) selected items."
            return
        }
        manualNames = names
        error = nil
    }

    private func refreshEntries() {
        let mask = fileMask.isEmpty ? "*" : fileMask
        let localSelected = selectedEntries.filter { $0.archiveURL == nil && !$0.isParent }
        let localURLs = BatchRenameFileList.enumerate(selected: localSelected.map(\.url), mask: mask, includeSubdirectories: includeSubdirectories)
        let originalByPath = Dictionary(uniqueKeysWithValues: localSelected.map { ($0.url.standardizedFileURL.path, $0) })
        entries = localURLs.map { url in
            if let existing = originalByPath[url.standardizedFileURL.path] { return existing }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isWritableKey])
            return FileEntry(url: url, name: url.lastPathComponent, isDirectory: false,
                             byteSize: Int64(values?.fileSize ?? 0), modifiedAt: values?.contentModificationDate,
                             attributes: values?.isWritable == false ? "R" : "", isParent: false)
        }
        entries.append(contentsOf: selectedEntries.filter { $0.archiveURL != nil && FileTransferService.matchesFile($0.name, mask: mask) })
        if manualMode { manualNames = proposed }
        error = nil
    }

    private func previewName(_ entry: FileEntry) -> String {
        guard includeSubdirectories || pathMode != .fileName else { return entry.name }
        return originalValue(entry)
    }

    private func originalValue(_ entry: FileEntry) -> String {
        switch pathMode {
        case .fileName: return entry.name
        case .fullPath: return entry.url.standardizedFileURL.path
        case .relativePath:
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return entry.url.standardizedFileURL.path.hasPrefix(prefix)
            ? String(entry.url.standardizedFileURL.path.dropFirst(prefix.count))
            : entry.url.path
        }
    }
}

private extension BatchRenameDialog {
    func splitPath(_ value: String) -> (prefix: String, component: String) {
        guard let slash = value.lastIndex(of: "/") else { return ("", value) }
        return (String(value[...slash]), String(value[value.index(after: slash)...]))
    }

    func replace(in input: String) -> String {
        let pattern: String
        if useRegularExpression { pattern = find }
        else {
            let escaped = NSRegularExpression.escapedPattern(for: find)
            pattern = wholeWords ? "(^|[\\p{P}\\s])(" + escaped + ")(?=$|[\\p{P}\\s])" : escaped
        }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        let matches = expression.matches(in: input, range: range)
        guard !matches.isEmpty else { return input }
        let chosen = replaceOnlyOnce ? Array(matches.prefix(1)) : matches
        var output = input
        for match in chosen.reversed() {
            guard let matchRange = Range(match.range, in: output) else { continue }
            let value: String
            if wholeWords && !useRegularExpression, match.numberOfRanges > 2, let wordRange = Range(match.range(at: 2), in: output) {
                value = String(output[matchRange.lowerBound..<wordRange.lowerBound]) + replacement + String(output[wordRange.upperBound..<matchRange.upperBound])
            } else { value = replacement }
            output.replaceSubrange(matchRange, with: value)
        }
        return output
    }

    func transformCase(_ value: String, mode: String) -> String {
        switch mode {
        case "lower": value.lowercased()
        case "upper": value.uppercased()
        case "mixed": value.prefix(1).uppercased() + value.dropFirst().lowercased()
        default: value
        }
    }
}

private struct RenamePreview: Identifiable {
    let id: Int
    let original: String
    let proposed: String
    let size: String
    let modified: String
}
