import Foundation

@main
struct VerifyFileAssociations {
    static func main() {
        let suite = "RetronAssociationCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = [
            FileAssociationRule(extensionName: ".TXT", viewerApplicationPath: "/Applications/QuickLook.app", editorApplicationPath: "~/Applications/TextEdit.app"),
            FileAssociationRule(extensionName: "md", viewerApplicationPath: "/Applications/Markdown.app")
        ]
        FileAssociationService.save(rules, defaults: defaults)
        let restored = FileAssociationService.load(defaults: defaults)
        precondition(restored == rules, "Associations did not persist")
        let file = URL(fileURLWithPath: "/tmp/NOTES.TxT")
        precondition(FileAssociationService.applicationPath(for: file, intent: .view, rules: restored) == "/Applications/QuickLook.app", "Extension matching or viewer lookup failed")
        precondition(FileAssociationService.applicationPath(for: file, intent: .edit, rules: restored) == "~/Applications/TextEdit.app".replacingOccurrences(of: "~", with: NSHomeDirectory()), "Editor path expansion failed")
        precondition(FileAssociationService.applicationPath(for: file, intent: .edit, rules: [restored[1], restored[0]]) == FileAssociationService.applicationPath(for: file, intent: .edit, rules: restored), "Unrelated rules changed the extension match")
        precondition(FileAssociationService.applicationPath(for: URL(fileURLWithPath: "/tmp/no-extension"), intent: .view, rules: restored) == nil, "Extensionless files should use the default viewer")
        print("Viewer/editor association persistence, case-insensitive extension matching, intent-specific paths, tilde expansion, and fallback passed.")
    }
}
