import AppKit
import Foundation
import JavaScriptCore

@objc private protocol ScriptItemExport: JSExport {
    var Name: String { get }
    var Path: String { get }
    var Size: NSNumber { get }
    var Attributes: String { get }
    var DateLastModified: Date? { get }
}

@objc private protocol ScriptItemCollectionExport: JSExport {
    var Count: Int { get }
    func Item(_ index: Int) -> ScriptItemBridge?
}

@MainActor @objc private protocol ScriptPanelExport: JSExport {
    var Path: String { get set }
    var Items: ScriptItemCollectionBridge { get }
    var SelectedItems: ScriptItemCollectionBridge { get }
    var FocusedItem: ScriptItemBridge? { get }
    func SelectAll()
    func DeselectAll()
    func StoreSelection()
}

@MainActor @objc private protocol RetronExport: JSExport {
    var LeftPanel: ScriptPanelBridge { get }
    var RightPanel: ScriptPanelBridge { get }
    var SourcePanel: ScriptPanelBridge { get }
    var TargetPanel: ScriptPanelBridge { get }
    var Version: String { get }
    func GetFullPath(_ path: String, _ panel: ScriptPanelBridge?) -> String
    func MatchesMask(_ file: String, _ mask: String) -> Bool
    func MsgBox(_ message: String)
    func ErrorDialog(_ message: String)
    func QuestionDialog(_ message: String) -> Bool
    func InputBox(_ prompt: String, _ defaultValue: String) -> String?
    func GetPersistentVal(_ key: String) -> String?
    func SetPersistentVal(_ key: String, _ value: String)
    func ViewFile(_ path: String)
}

private final class ScriptItemBridge: NSObject, ScriptItemExport {
    private let entry: FileEntry
    init(_ entry: FileEntry) { self.entry = entry }
    var Name: String { entry.name }
    var Path: String { entry.url.path }
    var Size: NSNumber { NSNumber(value: entry.byteSize) }
    var Attributes: String { entry.attributes }
    var DateLastModified: Date? { entry.modifiedAt }
}

private final class ScriptItemCollectionBridge: NSObject, ScriptItemCollectionExport {
    private let items: [ScriptItemBridge]
    init(_ items: [ScriptItemBridge]) { self.items = items }
    var Count: Int { items.count }
    func Item(_ index: Int) -> ScriptItemBridge? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }
}

@MainActor
private final class ScriptPanelBridge: NSObject, ScriptPanelExport {
    private let model: FilePaneModel
    private let store: () -> Void
    init(model: FilePaneModel, store: @escaping () -> Void) {
        self.model = model
        self.store = store
    }
    var Path: String {
        get { model.displayPath }
        set { model.navigate(toPath: newValue) }
    }
    var Items: ScriptItemCollectionBridge { ScriptItemCollectionBridge(model.entries.filter { !$0.isParent }.map(ScriptItemBridge.init)) }
    var SelectedItems: ScriptItemCollectionBridge { ScriptItemCollectionBridge(model.selectedEntries.filter { !$0.isParent }.map(ScriptItemBridge.init)) }
    var FocusedItem: ScriptItemBridge? {
        guard let entry = model.entries.first(where: { $0.id == model.focusedID }) else { return nil }
        return ScriptItemBridge(entry)
    }
    func SelectAll() { model.selectAll() }
    func DeselectAll() { model.unselectAll() }
    func StoreSelection() { store() }
}

@MainActor
private final class RetronBridge: NSObject, RetronExport {
    let LeftPanel: ScriptPanelBridge
    let RightPanel: ScriptPanelBridge
    let SourcePanel: ScriptPanelBridge
    let TargetPanel: ScriptPanelBridge
    let Version = "4.0 (macOS compatibility layer)"

    init(left: FilePaneModel, right: FilePaneModel, activeIsLeft: Bool) {
        LeftPanel = ScriptPanelBridge(model: left) { left.storeSelection() }
        RightPanel = ScriptPanelBridge(model: right) { right.storeSelection() }
        SourcePanel = activeIsLeft ? LeftPanel : RightPanel
        TargetPanel = activeIsLeft ? RightPanel : LeftPanel
    }

    func GetFullPath(_ path: String, _ panel: ScriptPanelBridge?) -> String {
        let base = panel.map { URL(fileURLWithPath: $0.Path, isDirectory: true) } ?? URL(fileURLWithPath: "/")
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }
    func MatchesMask(_ file: String, _ mask: String) -> Bool {
        mask.split(separator: ";").contains { pattern in
            let expression = "^" + pattern.map { character -> String in
                switch character {
                case "*": ".*"
                case "?": "."
                default: NSRegularExpression.escapedPattern(for: String(character))
                }
            }.joined() + "$"
            return (try? NSRegularExpression(pattern: expression, options: [.caseInsensitive]))?.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)) != nil
        }
    }
    func MsgBox(_ message: String) { showAlert("Retron Script", message, style: .informational) }
    func ErrorDialog(_ message: String) { showAlert("Script Error", message, style: .critical) }
    func QuestionDialog(_ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = "Retron Script"; alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func InputBox(_ prompt: String, _ defaultValue: String) -> String? {
        let alert = NSAlert(); alert.messageText = "Retron Script"; alert.informativeText = prompt
        let field = NSTextField(string: defaultValue); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    func GetPersistentVal(_ key: String) -> String? { UserDefaults.standard.string(forKey: "automation." + key) }
    func SetPersistentVal(_ key: String, _ value: String) { UserDefaults.standard.set(value, forKey: "automation." + key) }
    func ViewFile(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    private func showAlert(_ title: String, _ message: String, style: NSAlert.Style) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = style
        alert.runModal()
    }
}

@MainActor
enum AutomationPlugin {
    static var repository: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Retron Commander/Automation/scripts", isDirectory: true)
    }

    static func scripts() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: repository, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "js" }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    static func openRepository() {
        do {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let example = repository.appendingPathComponent("CountSelectedBytes.js")
            if !FileManager.default.fileExists(atPath: example.path),
               let bundled = Bundle.module.url(forResource: "CountSelectedBytes", withExtension: "js") {
                try FileManager.default.copyItem(at: bundled, to: example)
            }
            NSWorkspace.shared.open(repository)
        }
        catch { showError(error.localizedDescription) }
    }

    static func chooseAndRun(left: FilePaneModel, right: FilePaneModel, activeIsLeft: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.javaScript]; panel.directoryURL = repository
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { run(url, left: left, right: right, activeIsLeft: activeIsLeft) }
    }

    static func run(_ url: URL, left: FilePaneModel, right: FilePaneModel, activeIsLeft: Bool) {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let context = JSContext()!
            context.exceptionHandler = { _, _ in }
            context.setObject(RetronBridge(left: left, right: right, activeIsLeft: activeIsLeft), forKeyedSubscript: "Retron" as NSString)
            _ = context.evaluateScript(source, withSourceURL: url)
            if let exception = context.exception { showError("\(url.lastPathComponent): \(exception.toString() ?? "JavaScript error")") }
        } catch { showError(error.localizedDescription) }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Automation Script"; alert.informativeText = message; alert.alertStyle = .critical; alert.runModal()
    }
}
