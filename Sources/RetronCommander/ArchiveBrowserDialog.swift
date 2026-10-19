import SwiftUI

struct ArchiveBrowserDialog: View {
    private enum SpeedUnit: String, CaseIterable, Identifiable {
        case bytes = "B/s", kilobytes = "KB/s", megabytes = "MB/s", gigabytes = "GB/s"
        var id: String { rawValue }
        var multiplier: Double {
            switch self {
            case .bytes: 1
            case .kilobytes: 1_024
            case .megabytes: 1_048_576
            case .gigabytes: 1_073_741_824
            }
        }
    }

    let archive: URL
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ArchiveService.Item] = []
    @State private var selected: Set<String> = []
    @State private var error: String?
    @State private var isLoading = true
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var password = ""
    @State private var asksForPassword = false
    @State private var isExtracting = false
    @State private var transferPaused = false
    @State private var transferStatus = ""
    @State private var activeTransfer: TransferController?
    @State private var speedLimitEnabled = false
    @State private var speedLimitValue = "5"
    @State private var speedLimitUnit = SpeedUnit.megabytes

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "archivebox")
                Text(archive.lastPathComponent).font(.headline)
                Spacer()
                Text("\(items.count) items").foregroundStyle(.secondary)
            }
            .padding(12)
            Table(items, selection: $selected) {
                TableColumn("Name", value: \.path).width(min: 220, ideal: 360)
                TableColumn("Size") { item in
                    Text(item.isDirectory ? "<DIR>" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 100)
                TableColumn("Packed") { item in
                    Text(ByteCountFormatter.string(fromByteCount: item.packedSize, countStyle: .file))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 100)
                TableColumn("Modified", value: \.modified).width(min: 110, ideal: 140)
            }
            .overlay {
                if isLoading { ProgressView("Reading archive…") }
                else if let error { ContentUnavailableView("Could Not Read Archive", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if items.isEmpty { ContentUnavailableView("Empty Archive", systemImage: "archivebox") }
            }
            if asksForPassword {
                HStack {
                    SecureField("Archive password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { load() }
                    Button("Retry") { load() }
                        .disabled(password.isEmpty || isLoading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if isExtracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(transferStatus.isEmpty ? "Extracting…" : transferStatus)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(transferPaused ? "Resume" : "Pause") {
                        transferPaused.toggle()
                        activeTransfer?.setPaused(transferPaused)
                    }
                    Button("Cancel") { activeTransfer?.cancel() }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                HStack(spacing: 8) {
                    Toggle("Speed limit", isOn: $speedLimitEnabled).toggleStyle(.checkbox)
                    if speedLimitEnabled {
                        TextField("5", text: $speedLimitValue).textFieldStyle(.roundedBorder).frame(width: 70)
                        Picker("Unit", selection: $speedLimitUnit) {
                            ForEach(SpeedUnit.allCases) { unit in Text(unit.rawValue).tag(unit) }
                        }.labelsHidden().frame(width: 90)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            HStack {
                Text(isExtracting ? "Transfer in progress" : selected.isEmpty ? "Select items to extract, or extract the whole archive." : "\(selected.count) selected")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let testResult {
                    Text(testResult).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(isTesting ? "Testing…" : "Test") { testArchive() }
                    .disabled(isLoading || isTesting || isExtracting)
                Button("Extract All…") { extract(items) }
                    .disabled(isLoading || items.isEmpty || isExtracting)
                Button("Extract Selected…") { extract(items.filter { selected.contains($0.id) }) }
                    .disabled(isLoading || selected.isEmpty || isExtracting)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isExtracting)
            }
            .padding(12)
        }
        .frame(minWidth: 660, minHeight: 420)
        .task { load() }
        .onDisappear { password = "" }
    }

    private func load() {
        isLoading = true
        error = nil
        do {
            items = try ArchiveService.list(archive, password: password.isEmpty ? nil : password)
            asksForPassword = false
            error = nil
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            asksForPassword = true
            isLoading = false
        }
    }

    private func testArchive() {
        isTesting = true
        testResult = nil
        let enteredPassword = password.isEmpty ? nil : password
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.test(archive, password: enteredPassword)
                }.value
                testResult = output.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) ?? "Test passed."
                error = nil
                asksForPassword = false
            } catch {
                self.error = error.localizedDescription
                asksForPassword = true
                testResult = nil
            }
            isTesting = false
        }
    }

    private func extract(_ chosen: [ArchiveService.Item]) {
        guard !chosen.isEmpty else { return }
        let parent = archive.deletingLastPathComponent()
        let base = archive.deletingPathExtension().lastPathComponent
        var destination = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        let limit: Int64?
        if speedLimitEnabled {
            guard let value = Double(speedLimitValue), value > 0,
                  value * speedLimitUnit.multiplier <= Double(Int64.max) else {
                error = "Enter a positive speed limit."
                return
            }
            limit = Int64(value * speedLimitUnit.multiplier)
        } else { limit = nil }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("retron-standalone-extract-\(UUID().uuidString)", isDirectory: true)
        let enteredPassword = password.isEmpty ? nil : password
        let roots = topLevelSelections(chosen)
        let controller = TransferController(totalBytes: chosen.reduce(Int64(0)) { $0 + max(0, $1.size) }, operationName: "Extract") { snapshot in
            Task { @MainActor in
                let copied = ByteCountFormatter.string(fromByteCount: snapshot.bytesCopied, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file)
                transferStatus = snapshot.currentName.isEmpty ? "Extracting archive…" : "\(snapshot.currentName) · \(copied) / \(total)"
            }
        }
        controller.setSpeedLimit(limit)
        activeTransfer = controller
        isExtracting = true
        transferPaused = false
        transferStatus = "Extracting to a temporary folder…"
        error = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [archive, chosen, enteredPassword, temporary, roots, destination, controller] in
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try ArchiveService.extract(chosen, from: archive, to: temporary, password: enteredPassword, controller: controller)
                    let sourceURLs = roots.map { temporary.appendingPathComponent($0.path) }
                    controller.resetProgress(totalBytes: FileTransferService.totalSize(of: sourceURLs))
                    for item in roots {
                        guard controller.waitUntilResumed() else { throw FileTransferError.cancelled }
                        let relativeParent = (item.path as NSString).deletingLastPathComponent
                        let targetDirectory = relativeParent == "." ? destination : destination.appendingPathComponent(relativeParent, isDirectory: true)
                        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                        _ = try FileTransferService.transfer(
                            sources: [temporary.appendingPathComponent(item.path)],
                            to: targetDirectory,
                            move: false,
                            collisions: .fail,
                            preserveDirectoryDates: true,
                            preservePermissions: true,
                            preserveExtendedAttributes: true,
                            controller: controller
                        )
                    }
                }.value
                isExtracting = false
                activeTransfer = nil
                dismiss()
            } catch {
                isExtracting = false
                activeTransfer = nil
                transferPaused = false
                if controller.snapshot.cancelled {
                    self.error = "Extraction cancelled."
                } else {
                    self.error = error.localizedDescription
                    asksForPassword = true
                }
            }
        }
    }

    private func topLevelSelections(_ chosen: [ArchiveService.Item]) -> [ArchiveService.Item] {
        let ordered = chosen.sorted { $0.path.count < $1.path.count }
        var roots: [ArchiveService.Item] = []
        for item in ordered where !roots.contains(where: { item.path == $0.path || item.path.hasPrefix($0.path + "/") }) {
            roots.append(item)
        }
        return roots
    }
}
