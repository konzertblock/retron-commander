import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct VerifyBatchRenameFiles {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("retron-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let car = root.appendingPathComponent("Car", isDirectory: true)
        let house = root.appendingPathComponent("House", isDirectory: true)
        try fm.createDirectory(at: car, withIntermediateDirectories: true)
        try fm.createDirectory(at: house, withIntermediateDirectories: true)
        let first = car.appendingPathComponent("1.txt")
        let second = house.appendingPathComponent("2.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let items = [BatchRenameFileService.Item(url: first, isDirectory: false), BatchRenameFileService.Item(url: second, isDirectory: false)]

        let photos = ["Photos/1.txt", "Photos/2.txt"]
        let photoTargets = try BatchRenameFileService.rename(items, to: photos, root: root, pathMode: .relativePath)
        require(photoTargets.allSatisfy { fm.fileExists(atPath: $0.path) }, "relative-path rename creates destination folder and moves all files")
        let firstContent = try String(contentsOf: photoTargets[0], encoding: .utf8)
        require(firstContent == "one", "relative-path rename preserves file content")
        require(!fm.fileExists(atPath: first.path) && !fm.fileExists(atPath: second.path), "relative-path rename removes old locations")

        let fullTarget = root.appendingPathComponent("Archive/renamed.txt")
        _ = try BatchRenameFileService.rename([.init(url: photoTargets[0], isDirectory: false)], to: [fullTarget.path], root: root, pathMode: .fullPath)
        require(fm.fileExists(atPath: fullTarget.path), "full-path rename moves a file to the requested absolute destination")

        let folder = root.appendingPathComponent("Tree", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("child", isDirectory: true), withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("child/data.txt")
        try Data("tree".utf8).write(to: nested)
        let folderItem = BatchRenameFileService.Item(url: folder, isDirectory: true)
        do {
            _ = try BatchRenameFileService.rename([folderItem], to: ["Tree/inside"], root: root, pathMode: .relativePath)
            require(false, "directory cannot be moved inside itself")
        } catch BatchRenameFileService.Failure.invalidName {}
        require(fm.fileExists(atPath: nested.path), "rejected self-move leaves the directory intact")

        do {
            _ = try BatchRenameFileService.rename([.init(url: second, isDirectory: false)], to: ["../../outside"], root: root, pathMode: .relativePath)
            require(false, "relative rename cannot escape the panel root")
        } catch BatchRenameFileService.Failure.invalidName {}

        let movedFolder = root.appendingPathComponent("MovedTree", isDirectory: true)
        _ = try BatchRenameFileService.rename([folderItem], to: [movedFolder.path], root: root, pathMode: .fullPath)
        require(fm.fileExists(atPath: movedFolder.appendingPathComponent("child/data.txt").path), "full-path rename moves directory trees intact")
        print("Batch rename file operations passed: relative paths, full paths, directory moves, content preservation, and path guards.")
    }
}
