import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let retronCommand = Notification.Name("RetronCommander.Command")
}

func sendRetronCommand(_ action: String) {
    NotificationCenter.default.post(name: .retronCommand, object: action)
}

private enum ActiveSide { case left, right }
private enum WindowSheet: Identifiable {
    case search, compare, configuration, userMenu, connectNetwork, disconnectNetwork, networkNeighborhood, pluginManager, help, htmlViewer(URL), peViewer(URL), dbfViewer(URL), multimediaViewer(URL), multimediaExport([URL]), encryption(URL), mimeDecoder(URL?), ftpBrowser, trashRecovery, propertyListEditor(URL)
    case archive(URL), diskImage(URL), pack([FileEntry]), viewer(URL), checksums([URL]), selectionMask(Bool), diskMap(URL), duplicates(URL)
    case batchRename([FileEntry]), splitJoin([FileEntry]), properties([FileEntry]), selectedSize([URL]), fileComparison(URL, URL), commandOutput(String)
    case transfer([FileEntry], Bool, URL), speedLimit(TransferController)

    var id: String {
        switch self {
        case .search: "search"
        case .compare: "compare"
        case .configuration: "configuration"
        case .userMenu: "user-menu"
        case .connectNetwork: "connect-network"
        case .disconnectNetwork: "disconnect-network"
        case .networkNeighborhood: "network-neighborhood"
        case .pluginManager: "plugin-manager"
        case .help: "help"
        case .htmlViewer(let url): "html-viewer:\(url.path)"
        case .peViewer(let url): "pe-viewer:\(url.path)"
        case .dbfViewer(let url): "dbf-viewer:\(url.path)"
        case .multimediaViewer(let url): "multimedia-viewer:\(url.path)"
        case .multimediaExport(let urls): "multimedia-export:\(urls.map(\.path).joined(separator: "|"))"
        case .encryption(let url): "encryption:\(url.path)"
        case .mimeDecoder(let url): "mime-decoder:\(url?.path ?? "clipboard")"
        case .ftpBrowser: "ftp-browser"
        case .trashRecovery: "trash-recovery"
        case .propertyListEditor(let url): "plist-editor:\(url.path)"
        case .archive(let url): "archive:\(url.path)"
        case .diskImage(let url): "fat-image:\(url.path)"
        case .pack(let entries): "pack:\(entries.map(\.id).joined(separator: "|"))"
        case .viewer(let url): "viewer:\(url.path)"
        case .checksums(let urls): "checksums:\(urls.map(\.path).joined(separator: "|"))"
        case .selectionMask(let selecting): "selection-mask:\(selecting)"
        case .diskMap(let url): "disk-map:\(url.path)"
        case .duplicates(let url): "duplicates:\(url.path)"
        case .batchRename(let files): "batch-rename:\(files.map(\.id).joined(separator: "|"))"
        case .splitJoin(let files): "split-join:\(files.map(\.id).joined(separator: "|"))"
        case .properties(let files): "properties:\(files.map(\.id).joined(separator: "|"))"
        case .selectedSize(let urls): "selected-size:\(urls.map(\.path).joined(separator: "|"))"
        case .fileComparison(let left, let right): "file-comparison:\(left.path):\(right.path)"
        case .commandOutput: "command-output"
        case .transfer(let entries, let move, _): "transfer:\(move):\(entries.map(\.id).joined(separator: "|"))"
        case .speedLimit(let controller): "speed-limit:\(controller.id)"
        }
    }
}

@MainActor
private final class WindowState: ObservableObject {
    @Published var left: FilePaneModel
    @Published var right: FilePaneModel
    @Published var activeSide: ActiveSide
    @Published var actionError: String?
    @Published var transferStatus: String?
    @Published var activeTransferControllers: [TransferController] = []
    @Published var hotPaths: [String]
    @Published var renameTarget: FilePaneModel?
    @Published var createTarget: FilePaneModel?
    @Published var renameName = ""
    @Published var newDirectoryName = "New Folder"
    @Published var pendingDelete: FilePaneModel?
    @Published var pendingTransferConflict: (source: FilePaneModel, target: FilePaneModel, entries: [FileEntry], destination: URL, move: Bool, fileMask: String?, operationMask: String?, criteria: FileTransferCriteria?, onlyNonEmptyDirectories: Bool, preserveDirectoryDates: Bool, preservePermissions: Bool, preserveExtendedAttributes: Bool, speedLimit: Int64?, waitForQueue: Bool, count: Int)?
    @Published var sheet: WindowSheet?
    weak var leftTableView: NSTableView?
    weak var rightTableView: NSTableView?

    init() {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser
        func savedDirectory(for key: String) -> URL {
            guard let path = defaults.string(forKey: key) else { return home }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : home
        }
        left = FilePaneModel(directory: savedDirectory(for: "leftPanelPath"))
        right = FilePaneModel(directory: savedDirectory(for: "rightPanelPath"))
        activeSide = defaults.string(forKey: "activePanel") == "right" ? .right : .left
        hotPaths = defaults.stringArray(forKey: "hotPaths") ?? []
        left.showsHiddenFiles = defaults.bool(forKey: "leftShowsHiddenFiles")
        right.showsHiddenFiles = defaults.bool(forKey: "rightShowsHiddenFiles")
    }

    var active: FilePaneModel { activeSide == .left ? left : right }
    var passive: FilePaneModel { activeSide == .left ? right : left }

    func register(_ tableView: NSTableView, for side: ActiveSide) {
        if side == .left { leftTableView = tableView }
        else { rightTableView = tableView }
    }

    func focus(_ side: ActiveSide) {
        activeSide = side
        UserDefaults.standard.set(side == .left ? "left" : "right", forKey: "activePanel")
        let target = side == .left ? leftTableView : rightTableView
        if let target, target.window?.firstResponder !== target { target.window?.makeFirstResponder(target) }
    }
}

struct MainWindowView: View {
    @StateObject private var state = WindowState()
    @State private var pathDraftLeft = ""
    @State private var pathDraftRight = ""
    @State private var commandText = ""
    @State private var openNortonMenu: String?
    @FocusState private var pathFieldFocused: Bool
    @FocusState private var commandLineFocused: Bool
    @AppStorage("panelSplitRatio") private var panelSplitRatio = 0.5
    @AppStorage("retronTheme") private var themeName = RetronTheme.default.rawValue
    @AppStorage("functionKeyProfile") private var functionKeyProfileName = FunctionKeyProfile.retron.rawValue
    @AppStorage("handleFunctionKeys") private var handleFunctionKeys = true

    private let menus = ["Left", "Files", "Edit", "Commands", "Plugins", "Options", "Right", "Help"]
    private var currentTheme: RetronTheme { RetronTheme(rawValue: themeName) ?? .default }

    var body: some View {
        VStack(spacing: 0) {
            if currentTheme.usesIcons {
                toolbar
                driveBar
                pluginBar
            } else {
                nortonTitleBar
                nortonMenuStrip
                    .zIndex(openNortonMenu == nil ? 0 : 10)
            }
            GeometryReader { geometry in
                let splitWidth: CGFloat = 12
                let availableWidth = max(0, geometry.size.width - splitWidth)
                let ratio = min(0.8, max(0.2, panelSplitRatio))
                HStack(spacing: 0) {
                    pane(state.left, side: .left)
                        .frame(width: availableWidth * ratio)
                    panelSplitHandle(availableWidth: availableWidth)
                        .frame(width: splitWidth)
                    pane(state.right, side: .right)
                        .frame(width: availableWidth * (1 - ratio))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            if currentTheme.usesIcons { hotPathBar }
            commandLine
            functionBar
            if currentTheme.usesIcons { statusBar }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(currentTheme.background)
        .foregroundStyle(currentTheme.foreground)
        .font(currentTheme.font)
        .onReceive(NotificationCenter.default.publisher(for: .retronCommand)) { notification in
            guard let action = notification.object as? String else { return }
            performMenuCommand(action)
        }
        .alert("Operation could not be completed", isPresented: Binding(
            get: { state.actionError != nil }, set: { if !$0 { state.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { state.actionError = nil }
        } message: { Text(state.actionError ?? "") }
        .alert("Rename", isPresented: Binding(
            get: { state.renameTarget != nil }, set: { if !$0 { state.renameTarget = nil } }
        )) {
            TextField("New name", text: $state.renameName)
            Button("Rename") { perform { try state.renameTarget?.renameSelection(to: state.renameName) }; state.renameTarget = nil }
            Button("Cancel", role: .cancel) { state.renameTarget = nil }
        } message: { Text("Enter the new name for the selected item.") }
        .alert("Create directory", isPresented: Binding(
            get: { state.createTarget != nil }, set: { if !$0 { state.createTarget = nil } }
        )) {
            TextField("Directory name", text: $state.newDirectoryName)
            Button("Create") { perform { try state.createTarget?.createDirectory(named: state.newDirectoryName) }; state.createTarget = nil }
            Button("Cancel", role: .cancel) { state.createTarget = nil }
        } message: { Text("Create a directory in the active panel.") }
        .confirmationDialog("Delete selected items?", isPresented: Binding(
            get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { perform { try state.pendingDelete?.deleteSelection() }; state.pendingDelete = nil }
            Button("Cancel", role: .cancel) { state.pendingDelete = nil }
        } message: {
            Text(pendingDeleteMessage)
        }
        .confirmationDialog("Items already exist", isPresented: Binding(
            get: { state.pendingTransferConflict != nil }, set: { if !$0 { state.pendingTransferConflict = nil } }
        ), titleVisibility: .visible) {
            Button("Overwrite Existing Items") { resolveTransferConflict(.overwrite) }
            Button("Keep Both") { resolveTransferConflict(.keepBoth) }
            Button("Skip Existing Items") { resolveTransferConflict(.skip) }
            Button("Cancel", role: .cancel) { state.pendingTransferConflict = nil }
        } message: {
            Text("\(state.pendingTransferConflict?.count ?? 0) destination item(s) already exist in \(state.pendingTransferConflict?.destination.path ?? "the destination").")
        }
        .onAppear {
            pathDraftLeft = state.left.displayPath
            pathDraftRight = state.right.displayPath
            state.left.reload()
            state.right.reload()
        }
        .sheet(item: $state.sheet) { sheet in
            Group {
                switch sheet {
                case .search: SearchDialog(root: state.active.directory) { url in NSWorkspace.shared.open(url) }
                case .compare: DirectoryCompareDialog(left: state.left.directory, right: state.right.directory)
                case .configuration:
                    ConfigurationDialog(left: state.left, right: state.right, activeDirectory: state.active.directory, hotPaths: state.hotPaths, onHotPathsChanged: { paths in
                        state.hotPaths = paths
                        UserDefaults.standard.set(paths, forKey: "hotPaths")
                    }, onThemeChanged: { themeName = $0 }, onFunctionKeyProfileChanged: { functionKeyProfileName = $0 })
                case .userMenu:
                    UserMenuDialog(
                        directory: state.active.directory,
                        selectedItems: state.active.selectedEntries.filter { !$0.isParent }.map(\.url),
                        inactiveDirectory: state.passive.directory,
                        leftItems: state.left.selectedEntries.filter { !$0.isParent }.map(\.url),
                        rightItems: state.right.selectedEntries.filter { !$0.isParent }.map(\.url),
                        leftDirectory: state.left.directory,
                        rightDirectory: state.right.directory
                    ) { commands in
                        Task {
                            do {
                                var outputs: [String] = []
                                for invocation in commands {
                                    var isDirectory: ObjCBool = false
                                    guard FileManager.default.fileExists(atPath: invocation.workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                                        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: invocation.workingDirectory.path])
                                    }
                                    outputs.append(try await CommandRunner.run(invocation.command, in: invocation.workingDirectory))
                                }
                                state.sheet = .commandOutput(outputs.joined(separator: "\n\n"))
                            }
                            catch { state.actionError = error.localizedDescription }
                        }
                    }
                case .connectNetwork: NetworkConnectDialog()
                case .networkNeighborhood: NetworkNeighborhoodDialog()
                case .disconnectNetwork:
                    NetworkDisconnectDialog(volumes: networkVolumes) { url in
                        Task {
                            do {
                                try await unmount(url)
                                state.left.reload(); state.right.reload()
                            } catch { state.actionError = error.localizedDescription }
                        }
                    }
                case .peViewer(let url): PEInspectorDialog(file: url)
                case .dbfViewer(let url): DBFViewerDialog(file: url)
                case .multimediaViewer(let url): MultimediaViewerDialog(file: url)
                case .multimediaExport(let urls): MultimediaExportDialog(files: urls)
                case .encryption(let url): EncryptionDialog(file: url)
                case .pluginManager: PluginInventoryDialog()
                case .help: RetronHelpDialog()
                case .htmlViewer(let url): HTMLViewerDialog(file: url)
                case .mimeDecoder(let url): MIMEDecoderDialog(sourceFile: url)
                case .ftpBrowser: FTPBrowserDialog()
                case .trashRecovery: TrashRecoveryDialog()
                case .propertyListEditor(let url): PropertyListEditorDialog(source: url)
                case .archive(let url): ArchiveBrowserDialog(archive: url)
                case .diskImage(let url): DiskImageBrowserDialog(image: url)
                case .pack(let entries): ArchivePackDialog(entries: entries) { url in
                    state.active.reload()
                    state.active.selectedIDs = [url.path]
                }
                case .viewer(let url): FileViewerDialog(file: url, siblingFiles: state.active.entries.filter { !$0.isDirectory && !$0.isParent }.map(\.url))
                case .checksums(let urls): ChecksumDialog(files: urls)
                case .selectionMask(let selecting):
                    SelectionMaskDialog(selecting: selecting) { mask in state.active.applyMask(mask, selecting: selecting) }
                case .diskMap(let url): DiskMapDialog(root: url, onOpenInApp: { target in
                    state.active.navigate(to: target)
                    state.sheet = nil
                })
                case .duplicates(let url): DuplicateFinderDialog(root: url)
                case .batchRename(let entries):
                    BatchRenameDialog(entries: entries, root: state.active.directory) { candidates, names, pathMode, removeEmptiedDirectories in
                        try state.active.rename(candidates, to: names, root: state.active.directory, pathMode: pathMode, removeEmptiedDirectories: removeEmptiedDirectories)
                    }
                case .splitJoin(let entries):
                    SplitJoinDialog(entries: entries) { outputs in
                        state.active.reload()
                        state.active.selectedIDs = Set(outputs.map(\.path))
                    }
                case .properties(let entries):
                    FilePropertiesDialog(entries: entries, applyPermissions: { mode, selected in
                        try applyPermissions(mode, to: selected)
                    }, applyMacAttributes: { locked, extensionHidden, selected in
                        try applyMacAttributes(locked: locked, extensionHidden: extensionHidden, to: selected)
                    })
                case .selectedSize(let urls): SelectionSizeDialog(roots: urls)
                case .fileComparison(let left, let right): FileComparisonDialog(left: left, right: right)
                case .commandOutput(let output): CommandOutputDialog(output: output)
                case .transfer(let entries, let move, let destination):
                    CopyMoveDialog(entries: entries, moving: move, passivePath: destination, destinationChoices:
                        [("Left panel", state.left.directory), ("Right panel", state.right.directory)] + state.hotPaths.map { path in
                            (URL(fileURLWithPath: path).lastPathComponent, URL(fileURLWithPath: path, isDirectory: true))
                        }
                    ) { path, behavior, fileMask, operationMask, criteria, onlyNonEmptyDirectories, waitForQueue, preserveDirectoryDates, preservePermissions, preserveExtendedAttributes, speedLimit in
                        startTransfer(entries, from: state.active, to: path, move: move, collisions: behavior, fileMask: fileMask, operationMask: operationMask, criteria: criteria, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, speedLimit: speedLimit, waitForQueue: waitForQueue)
                    }
                case .speedLimit(let controller):
                    TransferSpeedLimitDialog(controller: controller)
            }
        }
    }
    }

    private var pendingDeleteMessage: String {
        let count = state.pendingDelete?.selectedEntries.count ?? 0
        return "\(count) item(s) will be moved to Trash."
    }

    private var menuBar: some View {
        HStack(spacing: 0) {
            ForEach(menus, id: \.self) { title in
                Menu(title) {
                    if title == "Files" {
                        Button("Quick Rename…  F2") { renameActive() }
                        Button("View  F3") { viewActive() }
                        Button("Edit  F4") { editActive() }
                        Divider()
                        Button("Copy…  F5") { beginTransfer(move: false) }
                        Button("Move/Rename…  F6") { beginTransfer(move: true) }
                        Button("Create Directory…  F7") { createDirectory() }
                        Button("Delete  F8", role: .destructive) { state.pendingDelete = state.active }
                        Divider()
                        Button("Pack selected items…") { showPackDialog() }
                        Button("Unpack selected archives…") { unpackSelection() }
                        Button("Batch Rename…") { showBatchRename() }
                        Button("Split / Combine File…") { showSplitJoin() }
                        Button("Properties…") { showProperties() }.keyboardShortcut(.return, modifiers: [.option])
                        Button("Calculate checksums…") { showChecksums() }
                        Button("Decode MIME…") { showMIMEDecoder() }
                        Button("View DBF Table…") { showDBFViewer() }
                        Button("View Multimedia Information…") { showMultimediaViewer() }
                        Button("Export Multimedia Information into HTML…") { showMultimediaExport() }
                        Button("Encrypt / Decrypt…") { showEncryption() }
                    } else if title == "Edit" {
                        Button("Select All  Ctrl+A") { state.active.selectAll() }.keyboardShortcut("a", modifiers: [.control])
                        Button("Unselect All  Ctrl+D") { state.active.unselectAll() }.keyboardShortcut("d", modifiers: [.control])
                        Button("Restore Selection") { state.active.restoreSelection() }
                        Button("Select Using Masks…") { showMaskDialog(selecting: true) }.keyboardShortcut("=", modifiers: [.control])
                        Button("Unselect Using Masks…") { showMaskDialog(selecting: false) }.keyboardShortcut("-", modifiers: [.control])
                        Button("Invert Selection") { state.active.invertSelection() }.keyboardShortcut("*", modifiers: [.control])
            } else if title == "Commands" {
                        Button("Refresh  Ctrl+R") { state.left.reload(); state.right.reload() }
                        Button("Swap Panels") { swapPanels() }
                        Button("Compare Directories") { state.sheet = .compare }
                        Button("Compare Selected Files") { compareSelectedFiles() }
                        Button("Find Files and Directories…") { state.sheet = .search }
                        Button("Calculate Space Occupied…") { showSelectedSize() }
                            .keyboardShortcut("q", modifiers: [.control])
                        Button("Calculate Directory Sizes  Ctrl+Shift+F10") { state.active.calculateDirectorySizes() }
                        Button("Disk Map…") { state.sheet = .diskMap(state.active.directory) }
                        Button("Find Duplicate Files…") { state.sheet = .duplicates(state.active.directory) }
                        Button("User Menu…  F9") { state.sheet = .userMenu }
                        Button("Connect Network Drive…  F11") { state.sheet = .connectNetwork }
                        Button("Disconnect…  F12") { state.sheet = .disconnectNetwork }
                        Button("Network Neighborhood…") { state.sheet = .networkNeighborhood }
                        Button("Restore from Trash…") { state.sheet = .trashRecovery }
                    } else if title == "Options" {
                        Button(state.active.showsHiddenFiles ? "Hide Hidden Files in Active Panel" : "Show Hidden Files in Active Panel") {
                            state.active.showsHiddenFiles.toggle()
                            state.active.reload()
                        }
                        Button("Add Current Path to Hot Paths") { addHotPath() }
                        Button("Clear Hot Paths", role: .destructive) { state.hotPaths.removeAll(); UserDefaults.standard.removeObject(forKey: "hotPaths") }
                        Button("Configuration…") { state.sheet = .configuration }
                        Button("Hot Paths…") { state.sheet = .configuration }
                    } else if title == "Plugins" {
                        Button("Plugin Coverage…") { state.sheet = .pluginManager }
                        Divider()
                        Button("Run Script…  Ctrl+Shift+A") { runAutomationScript() }
                            .keyboardShortcut("a", modifiers: [.control, .shift])
                        Menu("Automation Scripts") {
                            let scripts = AutomationPlugin.scripts()
                            if scripts.isEmpty {
                                Text("No scripts in repository").foregroundStyle(.secondary)
                            } else {
                                ForEach(scripts, id: \.path) { script in
                                    Button(script.deletingPathExtension().lastPathComponent) {
                                        AutomationPlugin.run(script, left: state.left, right: state.right, activeIsLeft: state.activeSide == .left)
                                    }
                                }
                            }
                        }
                        Button("Open Script Repository") { AutomationPlugin.openRepository() }
                        Divider()
                        Button("7-Zip Archive Browser") { openSelectedArchive() }
                        Button("Disk Image Browser") { showDiskImageBrowser() }
                        Button("FTP Client") { state.sheet = .ftpBrowser }
                        Button("Restore from Trash") { state.sheet = .trashRecovery }
                        Button("Network Neighborhood") { state.sheet = .networkNeighborhood }
                        Button("File Comparator") { compareSelectedFiles() }
                        Button("Portable Executable Viewer") { showPEViewer() }
                        Button("Property List Editor") { showPropertyListEditor() }
                        Button("MIME Decoder") { showMIMEDecoder() }
                        Button("DBF Viewer") { showDBFViewer() }
                        Button("Multimedia Viewer") { showMultimediaViewer() }
                        Button("Export Multimedia Info into HTML…") { showMultimediaExport() }
                        Button("Encrypt / Decrypt") { showEncryption() }
                    } else {
                        Button("Refresh") { state.active.reload() }
                        Button("Go to Parent Directory") { state.active.parent() }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 24)
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1) }
    }

    private func performMenuCommand(_ action: String) {
        switch action {
        case "rename": renameActive()
        case "view": viewActive()
        case "edit": editActive()
        case "copy": beginTransfer(move: false)
        case "move": beginTransfer(move: true)
        case "mkdir": createDirectory()
        case "delete": state.pendingDelete = state.active
        case "pack": showPackDialog()
        case "unpack": unpackSelection()
        case "batch-rename": showBatchRename()
        case "split": showSplitJoin()
        case "properties": showProperties()
        case "checksums": showChecksums()
        case "mime": showMIMEDecoder()
        case "dbf": showDBFViewer()
        case "multimedia": showMultimediaViewer()
        case "encrypt": showEncryption()
        case "search": state.sheet = .search
        case "compare": state.sheet = .compare
        case "compare-files": compareSelectedFiles()
        case "disk-map": state.sheet = .diskMap(state.active.directory)
        case "duplicates": state.sheet = .duplicates(state.active.directory)
        case "selected-size": showSelectedSize()
        case "directory-sizes": state.active.calculateDirectorySizes()
        case "refresh": state.left.reload(); state.right.reload()
        case "swap": swapPanels()
        case "user-menu": state.sheet = .userMenu
        case "connect": state.sheet = .connectNetwork
        case "disconnect": state.sheet = .disconnectNetwork
        case "network": state.sheet = .networkNeighborhood
        case "settings": state.sheet = .configuration
        case "help": state.sheet = .help
        case "select-all": state.active.selectAll()
        case "deselect-all": state.active.unselectAll()
        case "restore-selection": state.active.restoreSelection()
        case "invert-selection": state.active.invertSelection()
        case "select-mask": showMaskDialog(selecting: true)
        case "unselect-mask": showMaskDialog(selecting: false)
        case "hidden": state.active.showsHiddenFiles.toggle(); state.active.reload()
        case "plugin-coverage": state.sheet = .pluginManager
        case "ftp": state.sheet = .ftpBrowser
        case "automation": runAutomationScript()
        case "archive": openSelectedArchive()
        case "disk-image": showDiskImageBrowser()
        case "pe": showPEViewer()
        case "plist": showPropertyListEditor()
        case "multimedia-export": showMultimediaExport()
        case "trash": state.sheet = .trashRecovery
        case "hot-path": addHotPath()
        case "left-parent": state.focus(.left); state.left.parent()
        case "right-parent": state.focus(.right); state.right.parent()
        default: break
        }
    }

    private func runAutomationScript() {
        AutomationPlugin.chooseAndRun(left: state.left, right: state.right, activeIsLeft: state.activeSide == .left)
    }

    private func browseFolder(for model: FilePaneModel) {
        let panel = NSOpenPanel()
        panel.title = "Choose Panel Folder"
        panel.prompt = "Open Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.directory
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.navigate(to: folder)
    }

    private func panelSplitHandle(availableWidth: CGFloat) -> some View {
        ZStack {
            currentTheme == .nortonCommander ? currentTheme.background : Color(nsColor: .windowBackgroundColor)
            Rectangle()
                .fill(currentTheme == .nortonCommander ? currentTheme.panelBorder : Color.gray.opacity(0.55))
                .frame(width: currentTheme == .nortonCommander ? 2 : 1)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(currentTheme == .nortonCommander ? currentTheme.panelBorder : Color.gray.opacity(0.7)).frame(width: 2, height: 2)
                }
            }
            .padding(.vertical, 5)
            .background(currentTheme == .nortonCommander ? currentTheme.background : Color(nsColor: .controlColor))
            .clipShape(RoundedRectangle(cornerRadius: currentTheme == .nortonCommander ? 0 : 2))
        }
        .contentShape(Rectangle())
        .help("Drag to resize the panels")
        .accessibilityLabel("Panel splitter")
        .overlay {
            PanelSplitCapture(ratio: $panelSplitRatio, availableWidth: availableWidth)
                .accessibilityLabel("Panel splitter")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolbarButton("arrow.left", title: "Back") { state.active.back() }
            toolbarButton("arrow.right", title: "Forward") { state.active.forward() }
            toolbarButton("arrow.up", title: "Parent Directory") { state.active.parent() }
            Divider().frame(height: 24)
            toolbarButton("doc.on.doc", title: "Copy") { beginTransfer(move: false) }
            toolbarButton("folder", title: "Move") { beginTransfer(move: true) }
            toolbarButton("trash", title: "Delete") { state.pendingDelete = state.active }
            toolbarButton("folder.badge.plus", title: "Create Directory") { createDirectory() }
            Divider().frame(height: 24)
            toolbarButton("magnifyingglass", title: "Find") { state.sheet = .search }
            toolbarButton("arrow.left.arrow.right", title: "Swap Panels") { swapPanels() }
            toolbarButton("archivebox", title: "Pack selected items") { showPackDialog() }
            toolbarButton("archivebox.fill", title: "Unpack archive") { unpackSelection() }
            Spacer()
            toolbarButton("arrow.clockwise", title: "Refresh") { state.active.reload() }
            toolbarButton("slider.horizontal.3", title: "Configuration") { state.sheet = .configuration }
            toolbarButton("info.circle", title: "Properties") { showProperties() }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.28)).frame(height: 1) }
    }

    private var driveBar: some View {
        HStack(spacing: 7) {
            Text("Locations").font(.system(size: 12, weight: .semibold)).padding(.leading, 8)
            let home = FileManager.default.homeDirectoryForCurrentUser
            Button { state.active.navigate(to: home) } label: { driveButtonLabel("Home", url: home) }
                .buttonStyle(.borderless).help(home.path)
            ForEach(Array(mountedVolumes.enumerated()), id: \.element.path) { _, volume in
                Button {
                    state.active.navigate(to: volume)
                } label: { driveButtonLabel(volumeName(for: volume), url: volume) }
                .buttonStyle(.borderless)
                .help(volume.path)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .frame(height: 26)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.18)).frame(height: 1) }
    }

    private func driveButtonLabel(_ title: String, url: URL) -> some View {
        HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 16, height: 16)
            Text(title).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var pluginBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                Text("Plugins:").font(.system(size: 10, weight: .bold)).padding(.leading, 6)
                pluginButton("Search") { state.sheet = .search }
                pluginButton("Compare") { state.sheet = .compare }
                pluginButton("Checksums") { showChecksums() }
                pluginButton("File Compare") { compareSelectedFiles() }
                pluginButton("Disk Map") { state.sheet = .diskMap(state.active.directory) }
                pluginButton("Duplicates") { state.sheet = .duplicates(state.active.directory) }
                pluginButton("PE Viewer") { showPEViewer() }
                pluginButton("PLIST Editor") { showPropertyListEditor() }
                pluginButton("MIME Decode") { showMIMEDecoder() }
                pluginButton("FTP") { state.sheet = .ftpBrowser }
                pluginButton("Trash Recovery") { state.sheet = .trashRecovery }
                pluginButton("DBF Viewer") { showDBFViewer() }
                pluginButton("Multimedia") { showMultimediaViewer() }
                pluginButton("Encrypt") { showEncryption() }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1) }
    }

    private func pluginButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderless).font(.system(size: 10)).padding(.horizontal, 5)
    }

    private var hotPathBar: some View {
        HStack(spacing: 4) {
            Text("Hot Paths:").font(.system(size: 10, weight: .bold))
            ForEach(state.hotPaths, id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) { state.active.navigate(toPath: path) }
                    .buttonStyle(.borderless).font(.system(size: 10)).help(path)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var mountedVolumes: [URL] {
        let keys: Set<URLResourceKey> = [.volumeNameKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var nortonTitleBar: some View {
        HStack {
            Text("Norton Commander - Retron Commander")
                .font(.custom("Monaco", size: 14).weight(.bold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(Color(red: 0, green: 0, blue: 0.45))
    }

    private var nortonMenuStrip: some View {
        HStack(spacing: 0) {
            NortonDropdownMenu(title: "Links", openMenu: $openNortonMenu, entries: [
                .command("Parent Directory") { state.focus(.left); state.left.parent() },
                .command("Refresh") { state.left.reload() }
            ])
            NortonDropdownMenu(title: "Dateien", openMenu: $openNortonMenu, entries: [
                .command("View  F3") { viewActive() },
                .command("Edit  F4") { editActive() },
                .separator,
                .command("Copy  F5") { beginTransfer(move: false) },
                .command("Move  F6") { beginTransfer(move: true) },
                .command("Make Directory  F7") { createDirectory() },
                .command("Delete  F8") { state.pendingDelete = state.active }
            ])
            NortonDropdownMenu(title: "Datenträger", openMenu: $openNortonMenu, entries: [
                .command("Home") { state.active.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
            ] + mountedVolumes.map { volume in
                .command(volumeName(for: volume)) { state.active.navigate(to: volume) }
            })
            NortonDropdownMenu(title: "Befehle", openMenu: $openNortonMenu, entries: [
                .command("Find Files") { state.sheet = .search },
                .command("Compare Directories") { state.sheet = .compare },
                .command("Disk Map") { state.sheet = .diskMap(state.active.directory) },
                .command("Refresh Both Panels") { state.left.reload(); state.right.reload() }
            ])
            NortonDropdownMenu(title: "Rechts", openMenu: $openNortonMenu, entries: [
                .command("Parent Directory") { state.focus(.right); state.right.parent() },
                .command("Refresh") { state.right.reload() }
            ])
            Spacer(minLength: 12)
            Text(Date.now.formatted(date: .omitted, time: .shortened))
                .padding(.trailing, 10)
        }
        .font(.custom("Monaco", size: 14))
        .foregroundStyle(currentTheme.foreground)
        .padding(.horizontal, 8)
        .frame(height: 29)
        .background(currentTheme.toolbarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(currentTheme.panelBorder).frame(height: 1) }
    }

    private var networkVolumes: [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeNameKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: keys).volumeIsLocal) == false }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func unmount(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["unmount", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "RetronCommander.Network", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Could not disconnect \\(url.path)." : message])
            }
        }.value
    }

    private func volumeName(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
    }

    private func toolbarButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .regular)).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .frame(width: 30, height: 30)
        .help(title)
    }

    private func pane(_ model: FilePaneModel, side: ActiveSide) -> some View {
        let active = state.activeSide == side
        return VStack(spacing: 0) {
            if currentTheme == .nortonCommander {
                HStack {
                    TextField("Path", text: side == .left ? $pathDraftLeft : $pathDraftRight)
                        .focused($pathFieldFocused)
                        .textFieldStyle(.plain)
                        .font(.custom("Monaco", size: 14))
                        .multilineTextAlignment(.center)
                        .onSubmit { model.navigate(toPath: side == .left ? pathDraftLeft : pathDraftRight) }
                }
                .padding(.horizontal, 5)
                .frame(height: 28)
                .background(currentTheme.background)
                .overlay(alignment: .bottom) { Rectangle().fill(currentTheme.panelBorder).frame(height: 1) }
            } else {
                HStack(spacing: 4) {
                Text(side == .left ? "Left" : "Right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(active ? Color(red: 0.10, green: 0.34, blue: 0.62) : Color(nsColor: .controlColor))
                TextField("Path", text: side == .left ? $pathDraftLeft : $pathDraftRight)
                    .focused($pathFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { model.navigate(toPath: side == .left ? pathDraftLeft : pathDraftRight) }
                Button("Go") { model.navigate(toPath: side == .left ? pathDraftLeft : pathDraftRight) }
                    .buttonStyle(.borderless)
                Button { browseFolder(for: model) } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Choose a folder…")
                }
                .padding(.horizontal, 5)
                .frame(height: 28)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.45)).frame(height: 1) }
            }

            CompactFileTable(model: model, onOpen: { openSelection(in: model) }, onContextAction: { action in
                state.activeSide = side
                UserDefaults.standard.set(side == .left ? "left" : "right", forKey: "activePanel")
                switch action {
                case .open: openSelection(in: model)
                case .view: viewActive()
                case .edit: editActive()
                case .copy: beginTransfer(move: false)
                case .move: beginTransfer(move: true)
                case .rename: renameActive()
                case .delete: state.pendingDelete = model
                case .properties: showProperties()
                case .refresh: model.reload()
                }
            }, onFileDrop: { urls, moving in
                guard model.archiveURL == nil else { return }
                state.activeSide = side == .left ? .right : .left
                UserDefaults.standard.set(state.activeSide == .left ? "left" : "right", forKey: "activePanel")
                let entries = urls.compactMap { url -> FileEntry? in
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return FileEntry(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: values.isDirectory ?? false,
                        byteSize: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate,
                        attributes: "",
                        isParent: false
                    )
                }
                guard !entries.isEmpty else { return }
                state.sheet = .transfer(entries, moving, model.directory)
            }, onKeyDown: { event in
                state.activeSide = side
                UserDefaults.standard.set(side == .left ? "left" : "right", forKey: "activePanel")
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let withoutFunction = modifiers.subtracting(.function)
                if event.keyCode == 48, withoutFunction.subtracting(.shift).isEmpty {
                    state.focus(side == .left ? .right : .left)
                    return true
                }
                let controlFunctionKeyModifiers = withoutFunction.subtracting(.control)
                if controlFunctionKeyModifiers.isEmpty, withoutFunction.contains(.control) {
                    switch event.keyCode {
                    case 120: showProperties(); return true
                    case 99: model.toggleShortcutSort(column: "name"); return true
                    case 118: model.toggleShortcutSort(column: "ext"); return true
                    case 96: model.toggleShortcutSort(column: "date"); return true
                    case 97: model.toggleShortcutSort(column: "size"); return true
                    case 101: model.reload(); return true
                    case 109: state.sheet = .compare; return true
                    default: break
                    }
                }
                if withoutFunction == .option {
                    switch event.keyCode {
                    case 96: packSelection(); return true              // Alt+F5
                    case 97, 101: unpackSelection(); return true       // Alt+F6 / Alt+F9
                    case 98: state.sheet = .search; return true        // Alt+F7
                    case 109: showSelectedSize(); return true          // Alt+F10
                    default: break
                    }
                }
                if withoutFunction == [.control, .shift], event.keyCode == 109 {
                    model.calculateDirectorySizes() // Ctrl+Shift+F10
                    return true
                }
                if withoutFunction.isEmpty, handleFunctionKeys {
                    let functionSlotByKeyCode: [UInt16: Int] = [122: 0, 120: 1, 99: 2, 118: 3, 96: 4, 97: 5, 98: 6, 100: 7, 101: 8, 109: 9, 103: 10, 111: 11]
                    if let slot = functionSlotByKeyCode[event.keyCode], slot < functionKeyCount {
                        functionKeyAction(slot).1()
                        return true
                    }
                    switch event.keyCode {
                    case 122: state.sheet = .help; return true
                    case 120: renameActive(); return true
                    case 99: viewActive(); return true
                    case 118: editActive(); return true
                    case 96: beginTransfer(move: false); return true
                    case 97: beginTransfer(move: true); return true
                    case 98: createDirectory(); return true
                    case 100: state.pendingDelete = model; return true
                    case 101: state.sheet = .userMenu; return true
                    case 103: state.sheet = .connectNetwork; return true
                    case 111: state.sheet = .disconnectNetwork; return true
                    default: break
                    }
                }
                if withoutFunction.isEmpty, event.keyCode == 51 {
                    if let parent = model.entries.first(where: \.isParent) { model.open(parent) }
                    return true
                }
                if withoutFunction.isEmpty, event.keyCode == 36 { openSelection(in: model); return true }
                if withoutFunction.isEmpty, event.keyCode == 98 { pathFieldFocused = true; return true } // Shift+F7
                if withoutFunction == .option, event.keyCode == 123 { model.back(); return true }
                if withoutFunction == .option, event.keyCode == 124 { model.forward(); return true }
                if withoutFunction == .control {
                    switch event.keyCode {
                    case 0: model.selectAll(); return true                       // Ctrl+A
                    case 2: model.unselectAll(); return true                    // Ctrl+D
                    case 3: state.sheet = .search; return true                  // Ctrl+F
                    case 4: model.showsHiddenFiles.toggle(); model.reload(); return true // Ctrl+H
                    case 5: pathFieldFocused = true; return true                 // Ctrl+G
                    case 12: showSelectedSize(); return true                     // Ctrl+Q
                    case 15: model.reload(); return true                        // Ctrl+R
                    case 32: swapPanels(); return true                          // Ctrl+U
                    case 13: model.restoreSelection(); return true              // Ctrl+W
                    case 47: state.active.navigate(to: state.passive.directory); return true // Ctrl+.
                    case 49:
                        commandText = model.directory.path
                        commandLineFocused = true
                        return true                                             // Ctrl+Space
                    default: break
                    }
                }
                if withoutFunction == .control, event.keyCode == 116 {
                    if let parent = model.entries.first(where: \.isParent) { model.open(parent) }
                    return true
                }
                if withoutFunction == .control, event.keyCode == 121 { openSelection(in: model); return true }
                return false
            }, onTableReady: { state.register($0, for: side) })
            .onChange(of: model.directory) { _, newValue in
                UserDefaults.standard.set(newValue.path, forKey: side == .left ? "leftPanelPath" : "rightPanelPath")
                if side == .left { pathDraftLeft = model.displayPath } else { pathDraftRight = model.displayPath }
            }
            .onChange(of: model.archiveURL) { _, _ in
                if side == .left { pathDraftLeft = model.displayPath } else { pathDraftRight = model.displayPath }
            }
            .onChange(of: model.archiveDirectory) { _, _ in
                if side == .left { pathDraftLeft = model.displayPath } else { pathDraftRight = model.displayPath }
            }
            .onChange(of: model.showsHiddenFiles) { _, value in
                UserDefaults.standard.set(value, forKey: side == .left ? "leftShowsHiddenFiles" : "rightShowsHiddenFiles")
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { openSelection(in: model) })
            .background(currentTheme.background)

            if currentTheme.usesIcons { PanelFooter(model: model) }
        }
        .background(currentTheme == .nortonCommander ? currentTheme.background : Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().stroke(currentTheme == .nortonCommander ? currentTheme.panelBorder : (active ? Color(red: 0.10, green: 0.34, blue: 0.62) : Color.gray.opacity(0.6)), lineWidth: currentTheme == .nortonCommander ? 2 : (active ? 2 : 1)))
        .contentShape(Rectangle())
        .onTapGesture {
            state.activeSide = side
            UserDefaults.standard.set(side == .left ? "left" : "right", forKey: "activePanel")
        }
    }

    private var commandLine: some View {
        HStack(spacing: 6) {
            Text(state.active.directory.path + ">")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Command line", text: $commandText)
                .focused($commandLineFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { runCommandLine() }
                .help("Run a command in the active panel's directory")
            if currentTheme.usesIcons { Text("UTF-8")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: currentTheme == .nortonCommander ? 28 : 23)
        .foregroundStyle(currentTheme.commandForeground)
        .background(currentTheme.promptBackground)
        .overlay(alignment: .top) { Rectangle().fill(currentTheme == .nortonCommander ? currentTheme.panelBorder : Color.gray.opacity(0.35)).frame(height: 1) }
    }

    private var functionBar: some View {
        HStack(spacing: 1) {
            ForEach(0..<functionKeyCount, id: \.self) { slot in
                let (label, action) = functionKeyAction(slot)
                functionKey("F\(slot + 1)", label, action: action)
            }
        }
        .padding(.horizontal, currentTheme == .nortonCommander ? 0 : 8)
        .padding(.vertical, currentTheme == .nortonCommander ? 0 : 5)
        .frame(height: currentTheme == .nortonCommander ? 32 : nil)
        .background(currentTheme == .nortonCommander ? currentTheme.promptBackground : Color(nsColor: .controlBackgroundColor))
    }

    private var functionKeyCount: Int {
        if currentTheme == .nortonCommander { return 10 }
        return switch FunctionKeyProfile(rawValue: functionKeyProfileName) {
        case .compact: 8
        case .norton: 10
        default: 12
        }
    }

    private func functionKeyAction(_ slot: Int) -> (String, () -> Void) {
        if currentTheme == .nortonCommander {
            let classic: [(String, () -> Void)] = [
                ("Help", { state.sheet = .help }),
                ("User Menu", { state.sheet = .userMenu }),
                ("View", { viewActive() }),
                ("Edit", { editActive() }),
                ("Copy", { beginTransfer(move: false) }),
                ("Move", { beginTransfer(move: true) }),
                ("MkDir", { createDirectory() }),
                ("Delete", { state.pendingDelete = state.active }),
                ("PullDn", { NSApp.mainMenu?.items.first(where: { $0.title == "Files" })?.submenu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }),
                ("Quit", { NSApp.terminate(nil) })
            ]
            return classic[slot]
        }
        let profile = FunctionKeyProfile(rawValue: functionKeyProfileName) ?? .retron
        let base: [(String, () -> Void)] = [
            ("Help", { state.sheet = .help }),
            ("Rename", { renameActive() }),
            ("View", { viewActive() }),
            ("Edit", { editActive() }),
            ("Copy", { beginTransfer(move: false) }),
            ("Move", { beginTransfer(move: true) }),
            ("New Folder", { createDirectory() }),
            ("Delete", { state.pendingDelete = state.active }),
            ("User Menu", { state.sheet = .userMenu }),
            ("Menu", { NSApp.mainMenu?.items.first(where: { $0.title == "Files" })?.submenu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }),
            ("Connect", { state.sheet = .connectNetwork }),
            ("Disconnect", { state.sheet = .disconnectNetwork })
        ]
        switch profile {
        case .retron: return base[slot]
        case .norton:
            let actions = [base[0], base[1], base[2], base[3], base[4], ("Move", base[5].1), ("MkDir", base[6].1), base[7], ("PullDn", base[9].1), ("Quit", { NSApp.terminate(nil) }), base[10], base[11]]
            return actions[slot]
        case .mac:
            let actions = [base[0], base[1], ("Quick Look", base[2].1), ("Open", { openSelection(in: state.active) }), base[4], base[5], base[6], ("Move to Trash", base[7].1), ("Search", { state.sheet = .search }), base[9], base[10], base[11]]
            return actions[slot]
        case .compact: return base[slot]
        }
    }

    @ViewBuilder
    private func functionKey(_ key: String, _ title: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 3) {
                if currentTheme == .nortonCommander {
                    Text(String(key.dropFirst())).font(.custom("Monaco", size: 11)).foregroundStyle(.white)
                    Text(title).font(.custom("Monaco", size: 11)).foregroundStyle(.black).lineLimit(1).minimumScaleFactor(0.55).allowsTightening(true)
                } else {
                    Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
            }
            .padding(.horizontal, currentTheme == .nortonCommander ? 3 : 7)
            .padding(.vertical, currentTheme == .nortonCommander ? 2 : 4)
            .frame(maxWidth: .infinity)
            .background(currentTheme == .nortonCommander ? currentTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: currentTheme == .nortonCommander ? 0 : 7, style: .continuous))
            .background(currentTheme == .nortonCommander ? Color.black : Color(nsColor: .controlBackgroundColor))
            .overlay {
                if currentTheme.usesIcons { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7) }
            }
        }
        .buttonStyle(.plain)
        if handleFunctionKeys {
            button.keyboardShortcut(shortcut(for: key))
        } else {
            button
        }
    }

    private var statusBar: some View {
        HStack {
            Text(state.transferStatus ?? "\(state.active.selectedEntries.count) selected")
            if let controller = state.activeTransferControllers.last {
                Button(controller.snapshot.paused ? "Resume" : "Pause") {
                    controller.setPaused(!controller.snapshot.paused)
                }
                .buttonStyle(.borderless)
                speedMenu(for: controller)
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(.borderless)
                if state.activeTransferControllers.count > 1 {
                    Menu("Transfers (\(state.activeTransferControllers.count))") {
                        ForEach(state.activeTransferControllers, id: \.id) { item in
                            Menu(item.snapshot.currentName.isEmpty ? item.snapshot.operationName : "\(item.snapshot.operationName): \(item.snapshot.currentName)") {
                                Button(item.snapshot.paused ? "Resume" : "Pause") { item.setPaused(!item.snapshot.paused) }
                                speedMenu(for: item)
                                Button("Cancel") { item.cancel() }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            Spacer()
            Text(state.active.displayPath).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func speedMenu(for controller: TransferController) -> some View {
        Menu("Speed") {
            Button("No limit") { controller.setSpeedLimit(nil) }
            Divider()
            Button("100 KB/s") { controller.setSpeedLimit(100 * 1024) }
            Button("1 MB/s") { controller.setSpeedLimit(1024 * 1024) }
            Button("5 MB/s") { controller.setSpeedLimit(5 * 1024 * 1024) }
            Button("10 MB/s") { controller.setSpeedLimit(10 * 1024 * 1024) }
            Divider()
            Button("Set Speed Limit…") { state.sheet = .speedLimit(controller) }
        }
        .menuStyle(.borderlessButton)
    }

    private func shortcut(for key: String) -> KeyboardShortcut {
        let number = Int(key.dropFirst()) ?? 1
        let scalar = UnicodeScalar(0xF704 + number - 1)!
        return KeyboardShortcut(KeyEquivalent(Character(scalar)))
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func openSelection(in model: FilePaneModel) {
        guard let entry = model.selectedEntries.first else { return }
        model.open(entry)
        if !entry.isDirectory, ArchiveService.isSupportedArchive(entry.url), model.archiveURL == nil {
            state.sheet = .archive(entry.url)
        }
    }

    private func renameActive() {
        guard let entry = state.active.selectedEntries.first else { return }
        state.renameName = entry.name
        state.renameTarget = state.active
    }

    private func viewActive() {
        guard let entry = state.active.selectedEntries.first else { return }
        if !entry.isDirectory, openConfiguredApplication(for: entry.url, intent: .view) { return }
        if !entry.isDirectory && entry.url.pathExtension.lowercased() == "ima" { state.sheet = .diskImage(entry.url) }
        else if !entry.isDirectory && ArchiveService.isSupportedArchive(entry.url) { state.sheet = .archive(entry.url) }
        else if !entry.isDirectory && isPEFile(entry.url) { state.sheet = .peViewer(entry.url) }
        else if !entry.isDirectory && entry.url.pathExtension.lowercased() == "plist" { state.sheet = .propertyListEditor(entry.url) }
        else if !entry.isDirectory && entry.url.pathExtension.lowercased() == "dbf" { state.sheet = .dbfViewer(entry.url) }
        else if !entry.isDirectory && ["mp3", "mp2", "ogg", "oga", "wav", "wave", "wma", "vqf", "aac", "mp4", "m4a", "m4b", "669", "it", "mod", "mtm", "s3m", "stm", "xm"].contains(entry.url.pathExtension.lowercased()) { state.sheet = .multimediaViewer(entry.url) }
        else if !entry.isDirectory && ["html", "htm", "xhtml", "xml"].contains(entry.url.pathExtension.lowercased()) { state.sheet = .htmlViewer(entry.url) }
        else if entry.isDirectory { state.active.open(entry) }
        else { state.sheet = .viewer(entry.url) }
    }

    private func isPEFile(_ url: URL) -> Bool {
        ["exe", "dll", "sys", "ocx", "scr"].contains(url.pathExtension.lowercased())
    }

    private func showPEViewer() {
        guard let entry = state.active.selectedEntries.first, !entry.isDirectory, isPEFile(entry.url) else {
            state.actionError = "Select a PE executable, library, driver, or control file first."
            return
        }
        state.sheet = .peViewer(entry.url)
    }

    private func showPropertyListEditor() {
        if let selected = state.active.selectedEntries.first(where: { !$0.isDirectory && !$0.isParent }),
           selected.url.pathExtension.lowercased() == "plist" {
            state.sheet = .propertyListEditor(selected.url)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open Property List"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        if panel.runModal() == .OK, let url = panel.url { state.sheet = .propertyListEditor(url) }
    }

    private func showMIMEDecoder() {
        let selected = state.active.selectedEntries.first(where: { !$0.isDirectory && !$0.isParent })?.url
        state.sheet = .mimeDecoder(selected)
    }

    private func showDBFViewer() {
        guard let entry = state.active.selectedEntries.first, !entry.isDirectory,
              entry.url.pathExtension.lowercased() == "dbf" else {
            state.actionError = "Select a DBF table first."
            return
        }
        state.sheet = .dbfViewer(entry.url)
    }

    private func showMultimediaViewer() {
        guard let entry = state.active.selectedEntries.first, !entry.isDirectory, !entry.isParent,
              ["mp3", "mp2", "ogg", "oga", "wav", "wave", "wma", "vqf", "aac", "mp4", "m4a", "m4b", "669", "it", "mod", "mtm", "s3m", "stm", "xm"].contains(entry.url.pathExtension.lowercased()) else {
            state.actionError = "Select a supported multimedia file first."
            return
        }
        state.sheet = .multimediaViewer(entry.url)
    }

    private func showMultimediaExport() {
        let selected = state.active.selectedEntries.filter { entry in
            !entry.isDirectory && !entry.isParent && MultimediaInfoReader.extensions.contains(entry.url.pathExtension.lowercased())
        }
        guard !selected.isEmpty else {
            state.actionError = "Select one or more multimedia files to export."
            return
        }
        state.sheet = .multimediaExport(selected.map(\.url))
    }

    private func showEncryption() {
        guard let entry = state.active.selectedEntries.first, !entry.isDirectory, !entry.isParent else {
            state.actionError = "Select one file to encrypt or decrypt."
            return
        }
        state.sheet = .encryption(entry.url)
    }

    private func openSelectedArchive() {
        guard let entry = state.active.selectedEntries.first, !entry.isDirectory,
              ArchiveService.isSupportedArchive(entry.url) else {
            state.actionError = "Select a supported archive file first."
            return
        }
        if entry.url.pathExtension.lowercased() == "ima" { state.sheet = .diskImage(entry.url) }
        else { state.sheet = .archive(entry.url) }
    }

    private func showDiskImageBrowser() {
        guard let entry = state.active.selectedEntries.first, !entry.isDirectory, !entry.isParent else {
            state.actionError = "Select a FAT disk image first."
            return
        }
        state.sheet = .diskImage(entry.url)
    }

    private func editActive() {
        guard let entry = state.active.selectedEntries.first else { return }
        if !entry.isDirectory, openConfiguredApplication(for: entry.url, intent: .edit) { return }
        if !NSWorkspace.shared.open(entry.url) { state.actionError = "No application could open \(entry.name)." }
    }

    private func openConfiguredApplication(for file: URL, intent: FileAssociationIntent) -> Bool {
        guard let path = FileAssociationService.applicationPath(for: file, intent: intent, rules: FileAssociationService.load()) else { return false }
        let application = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: application.path) else {
            state.actionError = "The configured \(intent.rawValue) application does not exist: \(path)"
            return true
        }
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private func createDirectory() {
        state.newDirectoryName = "New Folder"
        state.createTarget = state.active
    }

    private func beginTransfer(move: Bool) {
        guard !state.active.selectedEntries.isEmpty else { return }
        state.sheet = .transfer(state.active.selectedEntries.filter { !$0.isParent }, move, state.passive.directory)
    }

    private func resolveTransferConflict(_ behavior: FilePaneModel.CollisionBehavior) {
        guard let transfer = state.pendingTransferConflict else { return }
        state.pendingTransferConflict = nil
        runTransfer(transfer.entries, source: transfer.source, target: transfer.target, destination: transfer.destination, move: transfer.move, collisions: behavior, fileMask: transfer.fileMask, operationMask: transfer.operationMask, criteria: transfer.criteria, onlyNonEmptyDirectories: transfer.onlyNonEmptyDirectories, preserveDirectoryDates: transfer.preserveDirectoryDates, preservePermissions: transfer.preservePermissions, preserveExtendedAttributes: transfer.preserveExtendedAttributes, speedLimit: transfer.speedLimit, waitForQueue: transfer.waitForQueue)
    }

    private func startTransfer(_ entries: [FileEntry], from source: FilePaneModel, to destination: URL, move: Bool, collisions: FilePaneModel.CollisionBehavior, fileMask: String?, operationMask: String? = nil, criteria: FileTransferCriteria? = nil, onlyNonEmptyDirectories: Bool, preserveDirectoryDates: Bool, preservePermissions: Bool, preserveExtendedAttributes: Bool, speedLimit: Int64?, waitForQueue: Bool) {
        if collisions == .fail {
            let count = entries.reduce(0) { total, entry in
                let targetName = FileOperationMask.apply(operationMask, to: entry.name)
                return total + transferConflictCount(
                    source: entry.url,
                    target: destination.appendingPathComponent(targetName),
                    fileMask: fileMask,
                    criteria: criteria
                )
            }
            if count > 0 {
                state.pendingTransferConflict = (source, state.passive, entries, destination, move, fileMask, operationMask, criteria, onlyNonEmptyDirectories, preserveDirectoryDates, preservePermissions, preserveExtendedAttributes, speedLimit, waitForQueue, count)
                return
            }
        }
        runTransfer(entries, source: source, target: state.passive, destination: destination, move: move, collisions: collisions, fileMask: fileMask, operationMask: operationMask, criteria: criteria, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, speedLimit: speedLimit, waitForQueue: waitForQueue)
    }

    private func transferConflictCount(source: URL, target: URL, fileMask: String?, criteria: FileTransferCriteria?) -> Int {
        var sourceStat = stat()
        guard lstat(source.path, &sourceStat) == 0 else { return 0 }
        let isDirectory = sourceStat.st_mode & S_IFMT == S_IFDIR
        if !isDirectory {
            if let fileMask, !FileTransferService.matchesFile(source.lastPathComponent, mask: fileMask) { return 0 }
            if let criteria, !criteria.includesFile(at: source) { return 0 }
            guard source.standardizedFileURL.path != target.standardizedFileURL.path else { return 0 }
            var targetStat = stat()
            return lstat(target.path, &targetStat) == 0 ? 1 : 0
        }

        var count = 0
        var targetStat = stat()
        let targetIsDirectory = lstat(target.path, &targetStat) == 0 && targetStat.st_mode & S_IFMT == S_IFDIR
        if lstat(target.path, &targetStat) == 0 && !targetIsDirectory { count += 1 }
        guard let children = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return count }
        for child in children {
            count += transferConflictCount(
                source: child,
                target: target.appendingPathComponent(child.lastPathComponent),
                fileMask: fileMask,
                criteria: criteria
            )
        }
        return count
    }

    private func runTransfer(_ entries: [FileEntry], source: FilePaneModel, target: FilePaneModel, destination: URL, move: Bool, collisions: FilePaneModel.CollisionBehavior, fileMask: String?, operationMask: String? = nil, criteria: FileTransferCriteria? = nil, onlyNonEmptyDirectories: Bool, preserveDirectoryDates: Bool, preservePermissions: Bool, preserveExtendedAttributes: Bool, speedLimit: Int64?, waitForQueue: Bool) {
        state.transferStatus = "Queued \(move ? "move" : "copy"): \(entries.count) item(s)"
        let totalBytes = entries.reduce(Int64(0)) { $0 + max(0, $1.byteSize) }
        let controller = TransferController(totalBytes: totalBytes, operationName: move ? "Move" : "Copy") { snapshot in
            Task { @MainActor in
                let copied = ByteCountFormatter.string(fromByteCount: snapshot.bytesCopied, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file)
                let stateText = snapshot.cancelled ? "Cancelling" : snapshot.paused ? "Paused" : (move ? "Moving" : "Copying")
                state.transferStatus = "\(stateText) \(snapshot.currentName) · \(copied) / \(total)"
            }
        }
        controller.setSpeedLimit(speedLimit)
        state.activeTransferControllers.append(controller)
        Task {
            do {
                if source.archiveURL == nil {
                    let sources = entries.map(\.url)
                    let measuredSize = await Task.detached(priority: .utility) {
                        FileTransferService.totalSize(of: sources, criteria: criteria)
                    }.value
                    controller.setTotalBytes(measuredSize)
                }
                let completed: [String]
                if let archive = source.archiveURL, entries.contains(where: { $0.archivePath != nil }) {
                    let virtual = entries.filter { $0.archivePath != nil }
                    let selections = virtual.compactMap { entry -> ArchiveService.Item? in
                        guard let path = entry.archivePath else { return nil }
                        return ArchiveService.Item(path: path, size: entry.byteSize, packedSize: 0, modified: "", isDirectory: entry.isDirectory)
                    }
                    let movedPaths: [String]
                    if waitForQueue {
                        movedPaths = try await FileTransferQueue.shared.enqueueArchive(selections: selections, from: archive, to: destination, move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, operationMask: operationMask, criteria: criteria, controller: controller)
                    } else {
                        movedPaths = try await Task.detached(priority: .userInitiated) {
                            try ArchiveTransferService.transfer(selections: selections, from: archive, to: destination, move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, operationMask: operationMask, criteria: criteria, controller: controller)
                        }.value
                    }
                    let completedPaths = Set(movedPaths)
                    completed = virtual.compactMap { entry in
                        guard let path = entry.archivePath, completedPaths.contains(path) else { return nil }
                        return entry.id
                    }
                } else if waitForQueue {
                    completed = try await FileTransferQueue.shared.enqueue(sources: entries.map(\.url), to: destination, move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, operationMask: operationMask, criteria: criteria, controller: controller)
                } else {
                    completed = try await Task.detached(priority: .userInitiated) {
                        try FileTransferService.transfer(sources: entries.map(\.url), to: destination, move: move, collisions: collisions, fileMask: fileMask, onlyNonEmptyDirectories: onlyNonEmptyDirectories, preserveDirectoryDates: preserveDirectoryDates, preservePermissions: preservePermissions, preserveExtendedAttributes: preserveExtendedAttributes, operationMask: operationMask, criteria: criteria, controller: controller)
                    }.value
                }
                source.selectedIDs.subtract(Set(completed))
                source.reload()
                target.reload()
                state.activeTransferControllers.removeAll { $0.id == controller.id }
                if state.activeTransferControllers.isEmpty { state.transferStatus = nil }
            } catch {
                state.activeTransferControllers.removeAll { $0.id == controller.id }
                if controller.snapshot.cancelled {
                    state.transferStatus = state.activeTransferControllers.isEmpty ? "Cancelled" : state.transferStatus
                } else {
                    if state.activeTransferControllers.isEmpty { state.transferStatus = nil }
                    state.actionError = error.localizedDescription
                }
            }
        }
    }

    private func packSelection() {
        showPackDialog()
    }

    private func showPackDialog() {
        let entries = state.active.selectedEntries.filter { !$0.isParent }
        guard !entries.isEmpty else {
            state.actionError = "Select one or more files or folders first."
            return
        }
        state.sheet = .pack(entries)
    }

    private func unpackSelection() {
        perform {
            let destinations = try ArchiveService.unpack(state.active.selectedEntries)
            state.active.reload()
            state.active.selectedIDs = Set(destinations.map(\.path))
        }
    }

    private func showChecksums() {
        let files = state.active.selectedEntries.filter { !$0.isDirectory && !$0.isParent }.map(\.url)
        guard !files.isEmpty else { return }
        state.sheet = .checksums(files)
    }

    private func showBatchRename() {
        let entries = state.active.selectedEntries.filter { !$0.isParent }
        guard !entries.isEmpty else { return }
        state.sheet = .batchRename(entries)
    }

    private func showSplitJoin() {
        let entries = state.active.selectedEntries.filter { !$0.isDirectory && !$0.isParent }
        guard !entries.isEmpty else { state.actionError = "Select a file or one numbered part first."; return }
        state.sheet = .splitJoin(entries)
    }

    private func showProperties() {
        let entries = state.active.selectedEntries.filter { !$0.isParent }
        guard !entries.isEmpty else { state.actionError = "Select at least one file or folder first."; return }
        state.sheet = .properties(entries)
    }

    private func showSelectedSize() {
        let urls = state.active.selectedEntries.filter { !$0.isParent }.map(\.url)
        guard !urls.isEmpty else { state.actionError = "Select at least one file or folder first."; return }
        state.sheet = .selectedSize(urls)
    }

    private func applyPermissions(_ mode: UInt16, to entries: [FileEntry]) throws {
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: Int(mode)]
        for entry in entries { try FileManager.default.setAttributes(attributes, ofItemAtPath: entry.url.path) }
        state.active.reload()
    }

    private func applyMacAttributes(locked: Bool, extensionHidden: Bool, to entries: [FileEntry]) throws {
        for entry in entries {
            try FileManager.default.setAttributes([.immutable: locked, .extensionHidden: extensionHidden], ofItemAtPath: entry.url.path)
        }
        state.active.reload()
    }

    private func compareSelectedFiles() {
        guard let left = state.left.selectedEntries.first, let right = state.right.selectedEntries.first,
              !left.isDirectory, !right.isDirectory else {
            state.actionError = "Select one file in each panel to compare."
            return
        }
        state.sheet = .fileComparison(left.url, right.url)
    }

    private func showMaskDialog(selecting: Bool) {
        state.sheet = .selectionMask(selecting)
    }

    private func addHotPath() {
        let path = state.active.directory.path
        guard !state.hotPaths.contains(path) else { return }
        state.hotPaths.append(path)
        UserDefaults.standard.set(state.hotPaths, forKey: "hotPaths")
    }

    private func swapPanels() {
        let leftPath = state.left.directory
        let rightPath = state.right.directory
        state.left.navigate(to: rightPath)
        state.right.navigate(to: leftPath)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { state.actionError = error.localizedDescription }
    }

    private func runCommandLine() {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        commandText = ""

        if command == "cd" {
            state.active.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        if command.hasPrefix("cd ") {
            state.active.navigate(toPath: String(command.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if command.hasPrefix("open ") {
            let rawPath = String(command.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let path = NSString(string: rawPath).expandingTildeInPath
            let url = URL(fileURLWithPath: path, relativeTo: state.active.directory).standardizedFileURL
            if !NSWorkspace.shared.open(url) { state.actionError = "Could not open \(url.path)." }
            return
        }

        let workingDirectory = state.active.directory
        Task {
            do { state.sheet = .commandOutput(try await CommandRunner.run(command, in: workingDirectory)) }
            catch { state.actionError = error.localizedDescription }
        }
    }
}

private struct NortonDropdownEntry: Identifiable {
    let id = UUID()
    let title: String?
    let action: (() -> Void)?

    static func command(_ title: String, action: @escaping () -> Void) -> NortonDropdownEntry {
        NortonDropdownEntry(title: title, action: action)
    }

    static var separator: NortonDropdownEntry { NortonDropdownEntry(title: nil, action: nil) }
}

private struct NortonDropdownMenu: View {
    let title: String
    @Binding var openMenu: String?
    let entries: [NortonDropdownEntry]

    var body: some View {
        Button {
                openMenu = openMenu == title ? nil : title
        } label: {
            Text(title + "  ▼")
                .font(.custom("Monaco", size: 13))
                .foregroundStyle(openMenu == title ? .yellow : RetronTheme.nortonCommander.foreground)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(openMenu == title ? RetronTheme.nortonCommander.selection : .clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if openMenu == title {
                VStack(spacing: 1) {
                    ForEach(entries) { entry in
                        if let label = entry.title, let action = entry.action {
                            NortonDropdownRow(title: label) {
                                action()
                                openMenu = nil
                            }
                        } else {
                            Rectangle()
                                .fill(RetronTheme.nortonCommander.panelBorder)
                                .frame(height: 1)
                                .padding(.horizontal, 5)
                        }
                    }
                }
                .padding(3)
                .frame(minWidth: 190, alignment: .leading)
                .background(RetronTheme.nortonCommander.background)
                .overlay(Rectangle().stroke(RetronTheme.nortonCommander.panelBorder, lineWidth: 2))
                .offset(y: 28)
                .zIndex(20)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .zIndex(openMenu == title ? 20 : 0)
    }
}

private struct NortonDropdownRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Monaco", size: 13))
                .foregroundStyle(isHovering ? .black : RetronTheme.nortonCommander.foreground)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(isHovering ? RetronTheme.nortonCommander.selection : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct PanelFooter: View {
    @ObservedObject var model: FilePaneModel

    var body: some View {
        HStack {
            Text(model.displayPath).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Text("\(model.entries.filter { !$0.isParent }.count) objects")
        }
        .font(.system(size: 10))
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CommandOutputDialog: View {
    let output: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command output").font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(output).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .frame(minWidth: 480, minHeight: 260)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
    }
}

private struct PanelSplitCapture: NSViewRepresentable {
    @Binding var ratio: Double
    let availableWidth: CGFloat

    func makeNSView(context: Context) -> SplitCaptureView {
        let view = SplitCaptureView()
        view.onDrag = { delta in
            ratio = min(0.8, max(0.2, context.coordinator.startRatio + delta / max(1, availableWidth)))
        }
        view.onBegin = { context.coordinator.startRatio = ratio }
        return view
    }

    func updateNSView(_ nsView: SplitCaptureView, context: Context) {
        nsView.onDrag = { delta in
            ratio = min(0.8, max(0.2, context.coordinator.startRatio + delta / max(1, availableWidth)))
        }
        nsView.onBegin = { context.coordinator.startRatio = ratio }
    }

    func makeCoordinator() -> Coordinator { Coordinator(startRatio: ratio) }

    final class Coordinator {
        var startRatio: Double
        init(startRatio: Double) { self.startRatio = startRatio }
    }
}

private final class SplitCaptureView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - dragStartX)
    }
}
