import AppKit
import SwiftUI

struct CopyMoveDialog: View {
    private enum SpeedUnit: String, CaseIterable, Identifiable {
        case bytes = "B/s"
        case kilobytes = "KB/s"
        case megabytes = "MB/s"
        case gigabytes = "GB/s"
        var id: String { rawValue }
        var multiplier: Double {
            switch self {
            case .bytes: 1
            case .kilobytes: 1024
            case .megabytes: 1024 * 1024
            case .gigabytes: 1024 * 1024 * 1024
            }
        }
    }

    let entries: [FileEntry]
    let moving: Bool
    let passivePath: URL
    let destinationChoices: [(String, URL)]
    let onTransfer: (URL, FilePaneModel.CollisionBehavior, String?, String?, FileTransferCriteria?, Bool, Bool, Bool, Bool, Bool, Int64?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destinationPath: String
    @AppStorage("copyMove.synchronizeNewer") private var synchronizeNewer = false
    @AppStorage("copyMove.filterByName") private var filterByName = false
    @AppStorage("copyMove.fileMask") private var fileMask = "*"
    @AppStorage("copyMove.renameWithMask") private var renameWithMask = false
    @AppStorage("copyMove.operationMask") private var operationMask = "*.*"
    @AppStorage("copyMove.onlyNonEmptyDirectories") private var onlyNonEmptyDirectories = false
    @AppStorage("copyMove.waitForQueue") private var waitForQueue = true
    @AppStorage("copyMove.preserveDirectoryDates") private var preserveDirectoryDates = true
    @AppStorage("copyMove.preservePermissions") private var preservePermissions = true
    @AppStorage("copyMove.preserveExtendedAttributes") private var preserveExtendedAttributes = true
    @AppStorage("copyMove.speedLimitEnabled") private var speedLimitEnabled = false
    @AppStorage("copyMove.speedLimitValue") private var speedLimitValue = "5"
    @AppStorage("copyMove.speedLimitUnit") private var speedLimitUnitRaw = SpeedUnit.megabytes.rawValue
    @State private var advancedOptionsExpanded = false
    @AppStorage("copyMove.minimumSize") private var minimumSizeText = ""
    @AppStorage("copyMove.maximumSize") private var maximumSizeText = ""
    @AppStorage("copyMove.filterModifiedAfter") private var filterModifiedAfter = false
    @AppStorage("copyMove.modifiedAfter") private var modifiedAfterTimestamp = Date().timeIntervalSince1970
    @AppStorage("copyMove.filterModifiedBefore") private var filterModifiedBefore = false
    @AppStorage("copyMove.modifiedBefore") private var modifiedBeforeTimestamp = Date().timeIntervalSince1970
    @AppStorage("copyMove.hiddenAttributeFilter") private var hiddenAttributeFilterRaw = FileAttributeFilter.any.rawValue
    @AppStorage("copyMove.readOnlyAttributeFilter") private var readOnlyAttributeFilterRaw = FileAttributeFilter.any.rawValue
    @AppStorage("copyMove.lockedAttributeFilter") private var lockedAttributeFilterRaw = FileAttributeFilter.any.rawValue
    @AppStorage("copyMove.destinationHistory") private var destinationHistoryJSON = "[]"
    @State private var error: String?

    private var speedLimitUnit: SpeedUnit { SpeedUnit(rawValue: speedLimitUnitRaw) ?? .megabytes }
    private var modifiedAfter: Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: modifiedAfterTimestamp) }, set: { modifiedAfterTimestamp = $0.timeIntervalSince1970 })
    }
    private var modifiedBefore: Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: modifiedBeforeTimestamp) }, set: { modifiedBeforeTimestamp = $0.timeIntervalSince1970 })
    }

    init(entries: [FileEntry], moving: Bool, passivePath: URL, destinationChoices: [(String, URL)] = [], onTransfer: @escaping (URL, FilePaneModel.CollisionBehavior, String?, String?, FileTransferCriteria?, Bool, Bool, Bool, Bool, Bool, Int64?) -> Void) {
        self.entries = entries
        self.moving = moving
        self.passivePath = passivePath
        self.destinationChoices = destinationChoices
        self.onTransfer = onTransfer
        _destinationPath = State(initialValue: passivePath.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(moving ? "Move / Rename" : "Copy").font(.headline)
            Text("\(entries.count) selected item(s) from \(entries.first?.url.deletingLastPathComponent().path ?? "")")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(moving ? "Move to:" : "Copy to:").frame(width: 62, alignment: .leading)
                TextField("Destination directory", text: $destinationPath).textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("Browse…") { browse() }
                if !destinationChoices.isEmpty {
                    Menu("Set To") {
                        ForEach(Array(destinationChoices.enumerated()), id: \.offset) { _, choice in
                            Button(choice.0) { destinationPath = choice.1.path }
                        }
                    }
                }
                if !destinationHistory.isEmpty {
                    Menu("Recent") {
                        ForEach(destinationHistory, id: \.self) { path in
                            Button(path) { destinationPath = path }
                        }
                    }
                }
            }
            Toggle("Overwrite older files and skip the rest (directory sync)", isOn: $synchronizeNewer)
                .toggleStyle(.checkbox)
            Toggle("Files named", isOn: $filterByName).toggleStyle(.checkbox)
            if filterByName {
                TextField("File masks (e.g. *.jpg;*.png|*.tmp)", text: $fileMask).textFieldStyle(.roundedBorder)
            }
            Toggle("Rename items using operation mask", isOn: $renameWithMask).toggleStyle(.checkbox)
            if renameWithMask {
                TextField("Operation mask (e.g. *.html or new_*.???)", text: $operationMask)
                    .textFieldStyle(.roundedBorder)
                Text("* keeps the rest of the name or extension; ? keeps one character. The first dot separates name and extension masks.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Toggle("Only files (do not create empty directories)", isOn: $onlyNonEmptyDirectories)
                .toggleStyle(.checkbox)
            Toggle("Wait until prior Copy/Move operations finish", isOn: $waitForQueue)
                .toggleStyle(.checkbox)
            Toggle("Preserve modification dates of directories", isOn: $preserveDirectoryDates)
                .toggleStyle(.checkbox)
            Toggle("Preserve ownership, permissions, and ACLs", isOn: $preservePermissions)
                .toggleStyle(.checkbox)
            Toggle("Include extended attributes and resource forks", isOn: $preserveExtendedAttributes)
                .toggleStyle(.checkbox)
            Toggle("Speed limit", isOn: $speedLimitEnabled).toggleStyle(.checkbox)
            if speedLimitEnabled {
                HStack(spacing: 8) {
                    Text("Maximum speed:").frame(width: 100, alignment: .leading)
                    TextField("5", text: $speedLimitValue).textFieldStyle(.roundedBorder).frame(width: 90)
                    Picker("Unit", selection: $speedLimitUnitRaw) {
                        ForEach(SpeedUnit.allCases) { unit in Text(unit.rawValue).tag(unit.rawValue) }
                    }.labelsHidden().frame(width: 100)
                }
            }
            DisclosureGroup("Advanced file filters", isExpanded: $advancedOptionsExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Size range (bytes):").frame(width: 150, alignment: .leading)
                        TextField("Minimum", text: $minimumSizeText).textFieldStyle(.roundedBorder)
                        Text("to")
                        TextField("Maximum", text: $maximumSizeText).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        Text("Attributes:").frame(width: 150, alignment: .leading)
                        attributeFilterPicker("Hidden", selection: $hiddenAttributeFilterRaw)
                        attributeFilterPicker("Read-only", selection: $readOnlyAttributeFilterRaw)
                        attributeFilterPicker("Locked", selection: $lockedAttributeFilterRaw)
                    }
                    HStack(spacing: 8) {
                        Toggle("Modified on or after", isOn: $filterModifiedAfter).toggleStyle(.checkbox).frame(width: 180, alignment: .leading)
                        if filterModifiedAfter { DatePicker("", selection: modifiedAfter, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
                    }
                    HStack(spacing: 8) {
                        Toggle("Modified on or before", isOn: $filterModifiedBefore).toggleStyle(.checkbox).frame(width: 180, alignment: .leading)
                        if filterModifiedBefore { DatePicker("", selection: modifiedBefore, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
                    }
                    Text("Attribute filters use macOS hidden, writable, and immutable properties. They apply to files; matching files inside folders are still copied.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            Text("Without this option, you will be asked how to handle existing items.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Text("Options are saved automatically.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Defaults") { resetDefaults() }
                    .help("Restore Retron's default Copy/Move options")
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(moving ? "Move" : "Copy") { submit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: NSString(string: destinationPath).expandingTildeInPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { destinationPath = url.path }
    }

    private func submit() {
        let path = NSString(string: destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            error = "Choose an existing destination directory."
            return
        }
        guard !filterByName || !fileMask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter at least one file mask."
            return
        }
        let trimmedOperationMask = operationMask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !renameWithMask || (!trimmedOperationMask.isEmpty && !trimmedOperationMask.contains("/") && !trimmedOperationMask.contains("\\")) else {
            error = "Enter a filename mask without path separators."
            return
        }
        guard !renameWithMask || entries.allSatisfy({ !FileOperationMask.apply(trimmedOperationMask, to: $0.name).isEmpty }) else {
            error = "The operation mask would create an empty filename."
            return
        }
        let speedLimit: Int64?
        if speedLimitEnabled {
            guard let value = Double(speedLimitValue), value > 0,
                  value * speedLimitUnit.multiplier <= Double(Int64.max) else {
                error = "Enter a positive speed limit."
                return
            }
            speedLimit = Int64(value * speedLimitUnit.multiplier)
        } else { speedLimit = nil }
        var minimumSize: Int64?
        var maximumSize: Int64?
        guard parseOptionalSize(minimumSizeText, into: &minimumSize),
              parseOptionalSize(maximumSizeText, into: &maximumSize) else {
            error = "File size limits must be non-negative whole byte counts."
            return
        }
        guard minimumSize == nil || maximumSize == nil || minimumSize! <= maximumSize! else {
            error = "The maximum file size must be at least the minimum size."
            return
        }
        let after = filterModifiedAfter ? modifiedAfter.wrappedValue : nil
        let before: Date? = filterModifiedBefore ? modifiedBefore.wrappedValue.addingTimeInterval(59.999) : nil
        guard after == nil || before == nil || after! <= before! else {
            error = "The end date must not precede the start date."
            return
        }
        rememberDestination(path)
        let criteria = FileTransferCriteria(
            minimumSize: minimumSize,
            maximumSize: maximumSize,
            modifiedAfter: after,
            modifiedBefore: before,
            hidden: FileAttributeFilter(rawValue: hiddenAttributeFilterRaw) ?? .any,
            readOnly: FileAttributeFilter(rawValue: readOnlyAttributeFilterRaw) ?? .any,
            locked: FileAttributeFilter(rawValue: lockedAttributeFilterRaw) ?? .any
        )
        dismiss()
        onTransfer(URL(fileURLWithPath: path, isDirectory: true), synchronizeNewer ? .overwriteOlderSkipNewer : .fail,
                   filterByName ? fileMask : nil, renameWithMask ? trimmedOperationMask : nil, criteria.isEmpty ? nil : criteria,
                   onlyNonEmptyDirectories, waitForQueue, preserveDirectoryDates, preservePermissions,
                   preserveExtendedAttributes, speedLimit)
    }

    private func parseOptionalSize(_ text: String, into result: inout Int64?) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { result = nil; return true }
        guard let value = Int64(cleaned), value >= 0 else { return false }
        result = value
        return true
    }

    private func attributeFilterPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(FileAttributeFilter.any.rawValue)
            Text("Has").tag(FileAttributeFilter.present.rawValue)
            Text("Not").tag(FileAttributeFilter.absent.rawValue)
        }
        .frame(maxWidth: 110)
    }

    private var destinationHistory: [String] {
        guard let data = destinationHistoryJSON.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths
    }

    private func rememberDestination(_ path: String) {
        let updated = ([path] + destinationHistory.filter { $0 != path }).prefix(10)
        guard let data = try? JSONEncoder().encode(Array(updated)),
              let encoded = String(data: data, encoding: .utf8) else { return }
        destinationHistoryJSON = encoded
    }

    private func resetDefaults() {
        synchronizeNewer = false
        filterByName = false
        fileMask = "*"
        renameWithMask = false
        operationMask = "*.*"
        onlyNonEmptyDirectories = false
        waitForQueue = true
        preserveDirectoryDates = true
        preservePermissions = true
        preserveExtendedAttributes = true
        speedLimitEnabled = false
        speedLimitValue = "5"
        speedLimitUnitRaw = SpeedUnit.megabytes.rawValue
        minimumSizeText = ""
        maximumSizeText = ""
        filterModifiedAfter = false
        filterModifiedBefore = false
        hiddenAttributeFilterRaw = FileAttributeFilter.any.rawValue
        readOnlyAttributeFilterRaw = FileAttributeFilter.any.rawValue
        lockedAttributeFilterRaw = FileAttributeFilter.any.rawValue
        modifiedAfterTimestamp = Date().timeIntervalSince1970
        modifiedBeforeTimestamp = Date().timeIntervalSince1970
    }
}
