import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationDialog: View {
    @ObservedObject var left: FilePaneModel
    @ObservedObject var right: FilePaneModel
    let activeDirectory: URL
    @State private var hotPaths: [String]
    @State private var fileAssociations = FileAssociationService.load()
    @State private var newPath = ""
    @State private var newExtension = ""
    @AppStorage("retronTheme") private var themeName = RetronTheme.default.rawValue
    @AppStorage("functionKeyProfile") private var functionKeyProfileName = FunctionKeyProfile.retron.rawValue
    @AppStorage("handleFunctionKeys") private var handleFunctionKeys = true
    @Environment(\.dismiss) private var dismiss
    let onHotPathsChanged: ([String]) -> Void
    let onThemeChanged: (String) -> Void
    let onFunctionKeyProfileChanged: (String) -> Void

    init(left: FilePaneModel, right: FilePaneModel, activeDirectory: URL, hotPaths: [String], onHotPathsChanged: @escaping ([String]) -> Void, onThemeChanged: @escaping (String) -> Void = { _ in }, onFunctionKeyProfileChanged: @escaping (String) -> Void = { _ in }) {
        self.left = left
        self.right = right
        self.activeDirectory = activeDirectory
        _hotPaths = State(initialValue: hotPaths)
        self.onHotPathsChanged = onHotPathsChanged
        self.onThemeChanged = onThemeChanged
        self.onFunctionKeyProfileChanged = onFunctionKeyProfileChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration").font(.headline)
            GroupBox("Appearance and keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Theme", selection: $themeName) {
                        ForEach(RetronTheme.allCases) { theme in Text(theme.rawValue).tag(theme.rawValue) }
                    }.onChange(of: themeName) { _, value in onThemeChanged(value) }
                    if RetronTheme(rawValue: themeName) == .nortonCommander {
                        Text("Norton Commander text mode: DOS blue panels, cyan file text, borders and scrollbars, yellow column headers, Monaco fixed-width type, Name/Size/Date/Time columns, square DOS-style dropdowns, a black command line, and classic F1–F10 labels. Future themes can define colors, type, icons, selection, scrollbars, row density, columns, menus and panel chrome in RetronTheme.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Default uses adaptive macOS materials, system typography, and native file icons.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Function keys", selection: $functionKeyProfileName) {
                        ForEach(FunctionKeyProfile.allCases) { profile in Text(profile.rawValue).tag(profile.rawValue) }
                    }.onChange(of: functionKeyProfileName) { _, value in onFunctionKeyProfileChanged(value) }
                    Text(FunctionKeyProfile(rawValue: functionKeyProfileName)?.description ?? "").font(.caption).foregroundStyle(.secondary)
                    Toggle("Use F1–F12 shortcuts in Retron Commander", isOn: $handleFunctionKeys)
                    HStack(alignment: .top, spacing: 8) {
                        Text("To use the top-row keys without Fn, macOS must send them as standard function keys. That macOS setting affects all apps.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Keyboard Settings…") { openKeyboardSettings() }
                            .controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Folder access") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Choose folders to grant macOS privacy access. The selected folders also become the corresponding panel locations.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose left panel folder…") { chooseFolder(for: left) }
                        Text(left.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("Choose right panel folder…") { chooseFolder(for: right) }
                        Text(right.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Panels") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show hidden files in left panel", isOn: Binding(get: { left.showsHiddenFiles }, set: { left.showsHiddenFiles = $0; left.reload() }))
                    Toggle("Show hidden files in right panel", isOn: Binding(get: { right.showsHiddenFiles }, set: { right.showsHiddenFiles = $0; right.reload() }))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Hot paths") {
                VStack(alignment: .leading, spacing: 8) {
                    List {
                        ForEach(hotPaths, id: \.self) { path in
                            HStack {
                                Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                                Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") { hotPaths.removeAll { $0 == path }; onHotPathsChanged(hotPaths) }
                            }
                        }
                    }
                    .frame(height: 140)
                    HStack {
                        TextField("Folder path", text: $newPath).textFieldStyle(.roundedBorder)
                        Button("Add") { addHotPath() }
                        Button("Add active folder") { newPath = activeDirectory.path; addHotPath() }
                    }
                }
            }
            GroupBox("View / Edit associations") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set extensions or filename masks (for example txt;md;*.log|secret-*.log) and optional macOS application bundle paths. Blank paths use the built-in viewer or the system default app.")
                        .font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(Array(fileAssociations.indices), id: \.self) { index in
                            HStack(spacing: 6) {
                                TextField("Extension / mask", text: Binding(
                                    get: { fileAssociations[index].extensionName },
                                    set: { fileAssociations[index].extensionName = $0; saveAssociations() }
                                )).frame(width: 145)
                                TextField("Viewer .app path", text: Binding(
                                    get: { fileAssociations[index].viewerApplicationPath },
                                    set: { fileAssociations[index].viewerApplicationPath = $0; saveAssociations() }
                                ))
                                Button("…") { chooseApplication(for: index, intent: .view) }.help("Choose viewer application")
                                TextField("Editor .app path", text: Binding(
                                    get: { fileAssociations[index].editorApplicationPath },
                                    set: { fileAssociations[index].editorApplicationPath = $0; saveAssociations() }
                                ))
                                Button("…") { chooseApplication(for: index, intent: .edit) }.help("Choose editor application")
                                Button("Remove") { fileAssociations.remove(at: index); saveAssociations() }
                            }
                        }
                    }.frame(height: 105)
                    HStack {
                        TextField("Extension or mask", text: $newExtension).frame(width: 220)
                        Button("Add Association") {
                            let ext = FileAssociationService.normalizedExtension(newExtension)
                            guard !ext.isEmpty,
                                  !fileAssociations.contains(where: { FileAssociationService.normalizedExtension($0.extensionName) == ext }) else { return }
                            fileAssociations.append(FileAssociationRule(extensionName: ext))
                            newExtension = ""
                            saveAssociations()
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 1040, height: 830)
    }

    private func addHotPath() {
        let path = NSString(string: newPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              !hotPaths.contains(path) else { return }
        hotPaths.append(path)
        newPath = ""
        onHotPathsChanged(hotPaths)
    }

    private func chooseFolder(for pane: FilePaneModel) {
        let panel = NSOpenPanel()
        panel.title = "Grant Access to a Folder"
        panel.prompt = "Open Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = pane.directory
        if panel.runModal() == .OK, let folder = panel.url { pane.navigate(to: folder) }
    }

    private func saveAssociations() {
        FileAssociationService.save(fileAssociations)
    }

    private func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseApplication(for index: Int, intent: FileAssociationIntent) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(intent.rawValue.capitalized) Application"
        panel.prompt = "Choose Application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let application = panel.url else { return }
        if intent == .view { fileAssociations[index].viewerApplicationPath = application.path }
        else { fileAssociations[index].editorApplicationPath = application.path }
        saveAssociations()
    }
}

private struct UserMenuItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var command: String
    var arguments: String
    var workingDirectory: String
    var isEnabled = true

    private enum CodingKeys: String, CodingKey { case id, title, command, arguments, workingDirectory, isEnabled }

    init(title: String, command: String, arguments: String = "", workingDirectory: String = "", isEnabled: Bool = true) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decode(String.self, forKey: .title)
        command = try values.decode(String.self, forKey: .command)
        arguments = try values.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct UserMenuInvocation: Sendable {
    let command: String
    let workingDirectory: URL
}

struct UserMenuDialog: View {
    let directory: URL
    let selectedItems: [URL]
    let inactiveDirectory: URL
    let leftItems: [URL]
    let rightItems: [URL]
    let leftDirectory: URL
    let rightDirectory: URL
    let run: ([UserMenuInvocation]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items = (UserDefaults.standard.data(forKey: "userMenuItems").flatMap { try? JSONDecoder().decode([UserMenuItem].self, from: $0) }) ?? []
    @State private var title = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var workingDirectory = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("User Menu").font(.headline)
            Text("Run saved commands in \(directory.path). Retron file and panel variables are available, along with $(MacHome), $(MacTemp), $(MacDesktop), $(MacDocuments), $(MacDownloads), $(MacLibrary), $(MacApplicationSupport), $(MacApplications), $(MacSystem), and $(MacAppBundle).")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).fontWeight(.medium)
                            Text([item.command, item.arguments].filter { !$0.isEmpty }.joined(separator: " ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            if !item.workingDirectory.isEmpty { Text("in \(item.workingDirectory)").font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
                        }
                        Spacer()
                        Button("Run") {
                            let commandTemplate = [item.command, item.arguments].filter { !$0.isEmpty }.joined(separator: " ")
                            let commands = UserMenuCommand.expand(
                                commandTemplate,
                                selectedItems: selectedItems,
                                activeDirectory: directory,
                                inactiveDirectory: inactiveDirectory,
                                leftItems: leftItems,
                                rightItems: rightItems,
                                leftDirectory: leftDirectory,
                                rightDirectory: rightDirectory
                            )
                            let workingPath = item.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                            let workingURL = workingPath.isEmpty ? directory : URL(fileURLWithPath: workingPath, isDirectory: true)
                            dismiss()
                            run(commands.map { UserMenuInvocation(command: $0, workingDirectory: workingURL) })
                        }.disabled(!item.isEnabled)
                        Button("Remove") { items.removeAll { $0.id == item.id }; save() }
                    }
                }
            }.frame(minHeight: 150)
            Divider()
            Text("Add command").font(.subheadline).fontWeight(.semibold)
            TextField("Menu label", text: $title)
            TextField("Shell command", text: $command).font(.system(.body, design: .monospaced))
            TextField("Arguments (optional; Retron variables supported)", text: $arguments).font(.system(.body, design: .monospaced))
            TextField("Working directory (optional; defaults to active panel)", text: $workingDirectory).font(.system(.body, design: .monospaced))
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Add") { add() }.keyboardShortcut(.return, modifiers: [.command])
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
    }

    private func add() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty else { error = "Enter both a menu label and a command."; return }
        guard !value.isEmpty || !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a shell command or arguments."; return }
        items.append(UserMenuItem(title: name, command: value, arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines), workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)))
        title = ""; command = ""; arguments = ""; workingDirectory = ""; error = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "userMenuItems") }
    }
}

struct NetworkConnectDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Network Share").font(.headline)
            Text("Enter an SMB share such as smb://server/share. macOS opens its network authentication and mount dialog.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("smb://server/share", text: $address).textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect", action: connect).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func connect() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["smb", "afp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            error = "Enter a valid smb://server/share or afp://server/share address."
            return
        }
        guard NSWorkspace.shared.open(url) else { error = "macOS could not open the network share."; return }
        dismiss()
    }
}

struct NetworkDisconnectDialog: View {
    let volumes: [URL]
    let disconnect: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disconnect Network Volume").font(.headline)
            if volumes.isEmpty {
                Text("No mounted network volumes were found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(volumes, id: \.path, selection: $selectedPath) { volume in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent)
                        Text(volume.path).font(.caption).foregroundStyle(.secondary)
                    }.tag(volume.path)
                }.frame(height: 180)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Disconnect") {
                    if let path = selectedPath, let volume = volumes.first(where: { $0.path == path }) { disconnect(volume); dismiss() }
                }
                .disabled(selectedPath == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
