import AppKit
import SwiftUI

struct ArchivePackDialog: View {
    let entries: [FileEntry]
    let onCreated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: ArchiveService.Format = .zip
    @State private var compressionLevel = 5
    @State private var name = ""
    @State private var encryptFiles = false
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var splitIntoVolumes = false
    @State private var volumeSizeMegabytes = 100
    @State private var moveOriginalsToTrash = false
    @State private var error: String?
    @State private var isPacking = false

    private var initialName: String {
        let files = entries.filter { !$0.isParent }
        return files.count == 1 ? files[0].name : "Selected Items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pack selected items").font(.headline)
            HStack {
                Text("Archive format:").frame(width: 120, alignment: .leading)
                Picker("Archive format", selection: $format) {
                    ForEach(ArchiveService.Format.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: format) { _, newFormat in
                    if newFormat != .zip && newFormat != .sevenZip { encryptFiles = false }
                }
                Text(".\(format.fileExtension)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Archive name:").frame(width: 120, alignment: .leading)
                TextField("Archive name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Encrypt files with password", isOn: $encryptFiles)
                .disabled(format != .zip && format != .sevenZip)
            if encryptFiles {
                HStack {
                    Text("Password:").frame(width: 120, alignment: .leading)
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Confirm:").frame(width: 120, alignment: .leading)
                    SecureField("Confirm password", text: $passwordConfirmation).textFieldStyle(.roundedBorder)
                }
                Text(format == .zip ? "ZIP uses AES-256 encryption." : "7-Zip also encrypts archive headers and file names.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 124)
            }
            HStack {
                Text("Compression:").frame(width: 120, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(compressionLevel) },
                    set: { compressionLevel = Int($0.rounded()) }
                ), in: 0...9, step: 1)
                .disabled(format == .pak)
                Text(format == .pak ? "No compression" : compressionLevel == 0 ? "Store" : "Level \(compressionLevel)")
                    .frame(width: 75, alignment: .trailing)
            }
            Toggle("Split into volumes", isOn: $splitIntoVolumes)
                .disabled(format != .sevenZip)
            if splitIntoVolumes {
                HStack {
                    Text("Volume size:").frame(width: 120, alignment: .leading)
                    TextField("Size in MB", value: $volumeSizeMegabytes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("MB each · first part ends in .001")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Toggle("Move originals to Trash after packing", isOn: $moveOriginalsToTrash)
                .toggleStyle(.checkbox)
            Text("\(entries.count) item(s) · \((entries.first?.archiveURL?.deletingLastPathComponent() ?? entries.first?.url.deletingLastPathComponent())?.path ?? "")")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isPacking ? "Packing…" : "Pack") { pack() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPacking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 510)
        .onAppear { if name.isEmpty { name = initialName } }
        .onDisappear { password = ""; passwordConfirmation = "" }
    }

    private func pack() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), trimmed != ".", trimmed != ".." else {
            error = "Enter an archive name without a path separator."
            return
        }
        if encryptFiles {
            guard !password.isEmpty else { error = "Enter a password to encrypt the archive."; return }
            guard password == passwordConfirmation else { error = "The passwords do not match."; return }
        }
        let directory = entries[0].archiveURL?.deletingLastPathComponent() ?? entries[0].url.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(trimmed).appendingPathExtension(format.fileExtension)
        let selectedEntries = entries
        let selectedFormat = format
        let selectedCompressionLevel = compressionLevel
        let selectedPassword = encryptFiles ? password : nil
        let selectedVolumeSize = splitIntoVolumes ? volumeSizeMegabytes : nil
        let removeOriginals = moveOriginalsToTrash
        isPacking = true
        error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.pack(
                        selectedEntries,
                        to: destination,
                        format: selectedFormat,
                        compressionLevel: selectedCompressionLevel,
                        password: selectedPassword,
                        volumeSizeMegabytes: selectedVolumeSize
                    )
                }.value
                if removeOriginals {
                    do {
                        try await Task.detached(priority: .utility) {
                            try removePackedSourceItems(selectedEntries)
                        }.value
                    } catch {
                        onCreated(result)
                        self.error = "Archive created, but some originals could not be removed: \(error.localizedDescription)"
                        isPacking = false
                        return
                    }
                }
                onCreated(result)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isPacking = false
            }
        }
    }
}

private func removePackedSourceItems(_ entries: [FileEntry]) throws {
    let selected = entries.filter { !$0.isParent }
    if let sourceArchive = selected.first?.archiveURL {
        guard selected.allSatisfy({ $0.archiveURL == sourceArchive }),
              selected.allSatisfy({ $0.archivePath != nil }) else {
            throw ArchiveError.mixedArchiveSelections
        }
        let items = selected.compactMap { entry -> ArchiveService.Item? in
            guard let path = entry.archivePath else { return nil }
            return ArchiveService.Item(path: path, size: entry.byteSize, packedSize: 0, modified: "", isDirectory: entry.isDirectory)
        }
        try ArchiveService.remove(items, from: sourceArchive)
        return
    }
    for entry in selected {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resultingURL)
    }
}
