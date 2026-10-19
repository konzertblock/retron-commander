import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct VerifyBatchRenameTemplate {
    static func main() {
        let root = URL(fileURLWithPath: "/tmp/rename root", isDirectory: true)
        let fileURL = root.appendingPathComponent("album/song name.MP3")
        let fixedDate = ISO8601DateFormatter().date(from: "2020-01-02T12:34:56Z")!
        let item = BatchRenameTemplate.Item(url: fileURL, name: "song name.MP3", isDirectory: false, byteSize: 4096, modifiedAt: fixedDate)
        let template = "$(OriginalName)|$(NamePart:upper)|$(ExtPart:lower)|$(Size)|$(RelativePath)|$(Date:yyyy-MM-dd)|$(Time:HH:mm:ss)|$(Counter:7,2,X,4,0)"
        let result = BatchRenameTemplate.expand(template, item: item, index: 1, root: root, pathMode: .relativePath)
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm:ss"
        let expectedTime = timeFormatter.string(from: fixedDate)
        require(result == "album/song name.MP3|SONG NAME|mp3|4096|album/song name.MP3|2020-01-02|\(expectedTime)|0009", "metadata, path, formatting, and counter variables")
        require(BatchRenameTemplate.expand("$(OriginalName)", item: item, index: 0, root: root, pathMode: .relativePath) == "album/song name.MP3", "relative-path mode includes the panel-relative path")
        require(BatchRenameTemplate.expand("$(OriginalName)|$(Drive)|$(Path)", item: item, index: 0, root: root, pathMode: .fullPath) == "\(fileURL.path)|/|\(fileURL.deletingLastPathComponent().path)", "full-path mode expands absolute item and parent paths")
        require(BatchRenameTemplate.foundationDatePattern(fromWindowsPattern: "ddd, MMMM d, yyyy 'at' h:mm tt") == "EEE, MMMM d, yyyy 'at' h:mm a", "Windows date/time tokens are converted for macOS formatting")

        let directory = BatchRenameTemplate.Item(url: root.appendingPathComponent("Folder", isDirectory: true), name: "Folder", isDirectory: true, byteSize: 0, modifiedAt: nil)
        require(BatchRenameTemplate.expand("$(OriginalName):$(ExtPart):$(Size)", item: directory, index: 0, root: root) == "Folder::", "directory values omit file-only extension and size")
        require(BatchRenameTemplate.expand("$(Unknown)", item: item, index: 0, root: root) == "$(Unknown)", "unknown variable remains visible for correction")
        print("Batch rename templates passed: names, extension, size, relative path, date/time, counter, and directory edge cases.")
    }
}
