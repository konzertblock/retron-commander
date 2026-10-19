import SwiftUI

private struct ACLRecord: Identifiable {
    let ordinal: Int
    let text: String
    var id: Int { ordinal }
}

struct FilePropertiesDialog: View {
    let entries: [FileEntry]
    let applyPermissions: (UInt16, [FileEntry]) throws -> Void
    let applyMacAttributes: (Bool, Bool, [FileEntry]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var permissions = ""
    @State private var isLocked = false
    @State private var extensionHidden = false
    @State private var aclRecords: [ACLRecord] = []
    @State private var selectedACL: Int?
    @State private var newACL = ""
    @State private var error: String?

    private var selected: FileEntry? { entries.first }
    private var attributes: [FileAttributeKey: Any] {
        guard let selected else { return [:] }
        return (try? FileManager.default.attributesOfItem(atPath: selected.url.path)) ?? [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entries.count == 1 ? "Properties" : "Properties (\(entries.count) items)").font(.headline)
            if entries.count > 1 {
                List(entries) { entry in Text(entry.name).lineLimit(1).help(entry.url.path) }
                    .frame(height: 120)
            } else if let selected {
                property("Name", selected.url.lastPathComponent)
                property("Path", selected.url.deletingLastPathComponent().path)
                property("Kind", selected.isDirectory ? "Folder" : (selected.url.pathExtension.uppercased().isEmpty ? "File" : "\(selected.url.pathExtension.uppercased()) file"))
                property("Size", selected.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: selected.byteSize, countStyle: .file))
                property("Modified", (attributes[.modificationDate] as? Date)?.formatted(date: .long, time: .shortened) ?? "—")
                property("Created", (attributes[.creationDate] as? Date)?.formatted(date: .long, time: .shortened) ?? "—")
                property("Owner", "\(attributes[.ownerAccountName] as? String ?? "—") : \(attributes[.groupOwnerAccountName] as? String ?? "—")")
            }
            HStack {
                Text("POSIX permissions (octal)")
                TextField("0644", text: $permissions).frame(width: 90).textFieldStyle(.roundedBorder)
                Button("Apply") { setPermissions() }
            }
            HStack(spacing: 12) {
                Toggle("Locked", isOn: $isLocked).toggleStyle(.checkbox)
                Toggle("Hide extension", isOn: $extensionHidden).toggleStyle(.checkbox)
                Button("Apply") { setFinderAttributes() }
            }
            GroupBox("macOS Access Control List") {
                VStack(alignment: .leading, spacing: 6) {
                    if entries.count == 1 {
                        List(aclRecords, selection: $selectedACL) { record in
                            Text(record.text).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        }
                        .frame(height: 92)
                        HStack {
                            TextField("ACL rule, e.g. user:staff allow read,write", text: $newACL)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") { addACL() }.disabled(newACL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Remove") { removeACL() }.disabled(selectedACL == nil)
                            Button("Refresh") { loadACL() }
                        }
                    } else {
                        Text("Add one ACL rule to all selected items.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("ACL rule, e.g. user:staff allow read,write", text: $newACL)
                                .textFieldStyle(.roundedBorder)
                            Button("Add to All") { addACL() }.disabled(newACL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            permissions = String(format: "%04o", mode)
            if selected != nil {
                isLocked = (attributes[.immutable] as? NSNumber)?.boolValue ?? false
                extensionHidden = (attributes[.extensionHidden] as? NSNumber)?.boolValue ?? false
                loadACL()
            }
        }
    }

    private func property(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }

    private func setPermissions() {
        guard let value = UInt16(permissions, radix: 8), value <= 0o7777 else { error = "Enter a valid octal permission value, such as 0644 or 0755."; return }
        do { try applyPermissions(value, entries); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func setFinderAttributes() {
        do { try applyMacAttributes(isLocked, extensionHidden, entries); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func loadACL() {
        guard let selected, entries.count == 1 else { aclRecords = []; return }
        do {
            let output = try runCommand("/bin/ls", arguments: ["-led", selected.url.path])
            let expression = try NSRegularExpression(pattern: #"^\s*(\d+):\s+(.+)$"#)
            aclRecords = output.components(separatedBy: .newlines).compactMap { line in
                let range = NSRange(line.startIndex..., in: line)
                guard let match = expression.firstMatch(in: line, range: range),
                      let ordinalRange = Range(match.range(at: 1), in: line),
                      let textRange = Range(match.range(at: 2), in: line),
                      let ordinal = Int(line[ordinalRange]) else { return nil }
                return ACLRecord(ordinal: ordinal, text: String(line[textRange]))
            }
        } catch {
            aclRecords = []
            self.error = error.localizedDescription
        }
    }

    private func addACL() {
        let rule = newACL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return }
        do {
            for entry in entries {
                _ = try runCommand("/bin/chmod", arguments: ["+a", rule, entry.url.path])
            }
            newACL = ""
            error = nil
            loadACL()
        } catch { self.error = error.localizedDescription }
    }

    private func removeACL() {
        guard entries.count == 1, let selected, let selectedACL else { return }
        do {
            _ = try runCommand("/bin/chmod", arguments: ["-a#", String(selectedACL), selected.url.path])
            self.selectedACL = nil
            error = nil
            loadACL()
        } catch { self.error = error.localizedDescription }
    }

    private func runCommand(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RetronCommander.ACL", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The ACL operation failed." : text
            ])
        }
        return text
    }
}
