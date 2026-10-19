import Foundation

@main
struct VerifyBatchRenameList {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retron-rename-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let nested = selected.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alpha = selected.appendingPathComponent("alpha.txt")
        let ignored = selected.appendingPathComponent("skip-me.txt")
        let beta = nested.appendingPathComponent("beta.txt")
        let other = nested.appendingPathComponent("other.bin")
        let direct = root.appendingPathComponent("direct.txt")
        try Data("a".utf8).write(to: alpha)
        try Data("s".utf8).write(to: ignored)
        try Data("b".utf8).write(to: beta)
        try Data("x".utf8).write(to: other)
        try Data("d".utf8).write(to: direct)
        let directoryLink = root.appendingPathComponent("folder-link")
        try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: "selected")

        let recursive = BatchRenameFileList.enumerate(selected: [selected, direct], mask: "*.txt|skip*", includeSubdirectories: true)
        precondition(Set(recursive.map(\.lastPathComponent)) == Set(["alpha.txt", "beta.txt", "direct.txt"]), "Recursive include or mask filtering is incorrect")
        precondition(!recursive.contains(where: { $0.lastPathComponent == "other.bin" || $0.lastPathComponent == "skip-me.txt" || $0.lastPathComponent == "nested" }), "The mask or files-only recursive behavior is incorrect")
        let linkResult = BatchRenameFileList.enumerate(selected: [directoryLink], mask: "*", includeSubdirectories: true)
        precondition(linkResult.map(\.lastPathComponent) == ["folder-link"], "A selected directory symlink was followed instead of treated as a file")

        let directOnly = BatchRenameFileList.enumerate(selected: [selected, direct], mask: "*", includeSubdirectories: false)
        precondition(Set(directOnly.map(\.lastPathComponent)) == Set(["selected", "direct.txt"]), "Non-recursive mode changed selected items")

        let moveRoot = root.appendingPathComponent("move-root", isDirectory: true)
        let oldDirectory = moveRoot.appendingPathComponent("old/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let movingFile = oldDirectory.appendingPathComponent("source.txt")
        try Data("move".utf8).write(to: movingFile)
        let pane = FilePaneModel(directory: moveRoot)
        let fileEntry = FileEntry(url: movingFile, name: "source.txt", isDirectory: false, byteSize: 4, modifiedAt: nil, attributes: "", isParent: false)
        try pane.rename([fileEntry], to: ["new/renamed.txt"], root: moveRoot, pathMode: .relativePath, removeEmptiedDirectories: true)
        let renamedFile = moveRoot.appendingPathComponent("new/renamed.txt")
        let renamedData = try Data(contentsOf: renamedFile)
        precondition(renamedData == Data("move".utf8), "Recursive move rename changed the file contents")
        precondition(!FileManager.default.fileExists(atPath: moveRoot.appendingPathComponent("old").path), "Remove emptied directories left an empty ancestor behind")
        print("Batch rename list passed: selected folders expand to masked descendant files, direct files remain included, and directory symlinks are not followed.")
    }
}
