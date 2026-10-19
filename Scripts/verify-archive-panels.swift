import Foundation

@main
struct VerifyArchivePanels {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retron-archive-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("folder/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("archive panel verification".utf8).write(to: source.appendingPathComponent("note.txt"))

        let symlinkSource = root.appendingPathComponent("note-link")
        try FileManager.default.createSymbolicLink(atPath: symlinkSource.path, withDestinationPath: "folder/sub/note.txt")
        let symlinkDestination = root.appendingPathComponent("symlink-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDestination, withIntermediateDirectories: true)
        _ = try FileTransferService.transfer(sources: [symlinkSource], to: symlinkDestination, move: false, collisions: .fail)
        let copiedLink = symlinkDestination.appendingPathComponent("note-link")
        guard try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path) == "folder/sub/note.txt" else {
            throw NSError(domain: "ArchiveCheck", code: 53, userInfo: [NSLocalizedDescriptionKey: "Copying a file symlink did not preserve the link target"])
        }

        let brokenSymlink = root.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(atPath: brokenSymlink.path, withDestinationPath: "missing-target")
        _ = try FileTransferService.transfer(sources: [brokenSymlink], to: symlinkDestination, move: false, collisions: .fail)
        let copiedBrokenLink = symlinkDestination.appendingPathComponent("broken-link")
        guard try FileManager.default.destinationOfSymbolicLink(atPath: copiedBrokenLink.path) == "missing-target" else {
            throw NSError(domain: "ArchiveCheck", code: 54, userInfo: [NSLocalizedDescriptionKey: "Copying a dangling symlink did not preserve the link target"])
        }
        let directorySymlink = root.appendingPathComponent("folder-link")
        try FileManager.default.createSymbolicLink(atPath: directorySymlink.path, withDestinationPath: "folder")
        _ = try FileTransferService.transfer(sources: [directorySymlink], to: symlinkDestination, move: false, collisions: .fail)
        let copiedDirectoryLink = symlinkDestination.appendingPathComponent("folder-link")
        guard try FileManager.default.destinationOfSymbolicLink(atPath: copiedDirectoryLink.path) == "folder" else {
            throw NSError(domain: "ArchiveCheck", code: 55, userInfo: [NSLocalizedDescriptionKey: "Copying a directory symlink followed the directory instead of preserving the link"])
        }
        try FileManager.default.createSymbolicLink(atPath: symlinkDestination.appendingPathComponent("note-link (2)").path, withDestinationPath: "absent")
        _ = try FileTransferService.transfer(sources: [symlinkSource], to: symlinkDestination, move: false, collisions: .keepBoth)
        let keptLink = symlinkDestination.appendingPathComponent("note-link (3)")
        guard try FileManager.default.destinationOfSymbolicLink(atPath: keptLink.path) == "folder/sub/note.txt" else {
            throw NSError(domain: "ArchiveCheck", code: 56, userInfo: [NSLocalizedDescriptionKey: "Keep-both collision handling ignored an existing dangling symlink"])
        }

        let archive = root.appendingPathComponent("fixture.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/7zz")
        zip.arguments = ["a", "-tzip", archive.path, "folder"]
        zip.currentDirectoryURL = root
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.standardError
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw NSError(domain: "ArchiveCheck", code: Int(zip.terminationStatus)) }
        let zipTestOutput = try ArchiveService.test(archive)
        guard zipTestOutput.contains("Everything is Ok") else {
            throw NSError(domain: "ArchiveCheck", code: 27, userInfo: [NSLocalizedDescriptionKey: "7-Zip test did not report a successful ZIP integrity check"])
        }
        let damagedZip = root.appendingPathComponent("damaged.zip")
        try Data("not an archive".utf8).write(to: damagedZip)
        var damagedZipRejected = false
        do { _ = try ArchiveService.test(damagedZip) } catch { damagedZipRejected = true }
        guard damagedZipRejected else {
            throw NSError(domain: "ArchiveCheck", code: 28, userInfo: [NSLocalizedDescriptionKey: "7-Zip integrity check accepted a corrupt archive"])
        }

        let model = FilePaneModel(directory: root)
        guard let archiveEntry = model.entries.first(where: { $0.name == "fixture.zip" }) else {
            throw NSError(domain: "ArchiveCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "archive missing from filesystem panel"])
        }
        model.open(archiveEntry)
        guard model.archiveURL?.resolvingSymlinksInPath().path == archive.resolvingSymlinksInPath().path,
              model.entries.contains(where: { $0.name == "folder" && $0.isDirectory }) else {
            throw NSError(domain: "ArchiveCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "archive root listing failed: archive=\(String(describing: model.archiveURL)); error=\(String(describing: model.errorMessage)); entries=\(model.entries.map(\.name))"])
        }
        model.open(model.entries.first(where: { $0.name == "folder" })!)
        guard model.entries.contains(where: { $0.name == "sub" && $0.isDirectory }) else {
            throw NSError(domain: "ArchiveCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "nested directory listing failed"])
        }
        model.open(model.entries.first(where: { $0.name == "sub" })!)
        guard let note = model.entries.first(where: { $0.name == "note.txt" }), note.byteSize == 26 else {
            throw NSError(domain: "ArchiveCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "nested file metadata failed"])
        }
        model.selectedIDs = [note.id]
        let output = root.appendingPathComponent("extracted", isDirectory: true)
        try model.extractSelection(to: output)
        let extracted = output.appendingPathComponent("folder/sub/note.txt")
        guard try Data(contentsOf: extracted) == Data("archive panel verification".utf8) else {
            throw NSError(domain: "ArchiveCheck", code: 5, userInfo: [NSLocalizedDescriptionKey: "selected extraction did not preserve file contents"])
        }
        let renameArchive = root.appendingPathComponent("rename-fixture.zip")
        try FileManager.default.copyItem(at: archive, to: renameArchive)
        let renameModel = FilePaneModel(directory: root)
        guard let renameArchiveEntry = renameModel.entries.first(where: { $0.name == "rename-fixture.zip" }) else {
            throw NSError(domain: "ArchiveCheck", code: 19, userInfo: [NSLocalizedDescriptionKey: "rename fixture missing from panel"])
        }
        renameModel.open(renameArchiveEntry)
        guard let folderToRename = renameModel.entries.first(where: { $0.name == "folder" }) else {
            throw NSError(domain: "ArchiveCheck", code: 20, userInfo: [NSLocalizedDescriptionKey: "rename fixture root listing failed"])
        }
        try renameModel.rename([folderToRename], to: ["renamed"])
        guard renameModel.entries.contains(where: { $0.name == "renamed" && $0.isDirectory }),
              try ArchiveService.list(renameArchive).contains(where: { $0.path == "renamed/sub/note.txt" }) else {
            throw NSError(domain: "ArchiveCheck", code: 21, userInfo: [NSLocalizedDescriptionKey: "batch folder rename did not update the archive subtree"])
        }
        guard let renamedFolder = renameModel.entries.first(where: { $0.name == "renamed" }) else {
            throw NSError(domain: "ArchiveCheck", code: 22, userInfo: [NSLocalizedDescriptionKey: "renamed folder missing from refreshed panel"])
        }
        renameModel.selectedIDs = [renamedFolder.id]
        try renameModel.renameSelection(to: "final")
        guard renameModel.entries.contains(where: { $0.name == "final" && $0.isDirectory }),
              try ArchiveService.list(renameArchive).contains(where: { $0.path == "final/sub/note.txt" }) else {
            throw NSError(domain: "ArchiveCheck", code: 23, userInfo: [NSLocalizedDescriptionKey: "F2 folder rename did not update the archive subtree"])
        }
        let packedSelection = root.appendingPathComponent("packed-selection.zip")
        _ = try ArchiveService.pack([note], to: packedSelection, format: .zip, compressionLevel: 5)
        guard let packedItem = try ArchiveService.list(packedSelection).first(where: { $0.path == "note.txt" }) else {
            throw NSError(domain: "ArchiveCheck", code: 15, userInfo: [NSLocalizedDescriptionKey: "packing from a virtual archive selection lost its selected file"])
        }
        let packedExtract = root.appendingPathComponent("packed-selection-extract", isDirectory: true)
        try ArchiveService.extract([packedItem], from: packedSelection, to: packedExtract)
        guard try Data(contentsOf: packedExtract.appendingPathComponent("note.txt")) == Data("archive panel verification".utf8) else {
            throw NSError(domain: "ArchiveCheck", code: 16, userInfo: [NSLocalizedDescriptionKey: "packed virtual selection changed its file contents"])
        }
        let protectedZip = root.appendingPathComponent("protected.zip")
        _ = try ArchiveService.pack([pakEntryForVerification(source: source.appendingPathComponent("note.txt"))], to: protectedZip, format: .zip, compressionLevel: 5, password: "testpass")
        try ArchiveService.test(protectedZip, password: "testpass")
        var wrongZipPasswordRejected = false
        do { try ArchiveService.test(protectedZip, password: "wrongpass") } catch { wrongZipPasswordRejected = true }
        guard wrongZipPasswordRejected else {
            throw NSError(domain: "ArchiveCheck", code: 30, userInfo: [NSLocalizedDescriptionKey: "AES-encrypted ZIP accepted an incorrect password"])
        }
        let protectedZipItems = try ArchiveService.list(protectedZip)
        let protectedZipOutput = root.appendingPathComponent("protected-zip-output", isDirectory: true)
        try ArchiveService.extract(protectedZipItems, from: protectedZip, to: protectedZipOutput, password: "testpass")
        guard try Data(contentsOf: protectedZipOutput.appendingPathComponent("note.txt")) == Data("archive panel verification".utf8) else {
            throw NSError(domain: "ArchiveCheck", code: 31, userInfo: [NSLocalizedDescriptionKey: "AES-encrypted ZIP extraction changed file contents"])
        }
        let protected7z = root.appendingPathComponent("protected.7z")
        _ = try ArchiveService.pack([pakEntryForVerification(source: source.appendingPathComponent("note.txt"))], to: protected7z, format: .sevenZip, compressionLevel: 5, password: "testpass")
        var protected7zListingRequiresPassword = false
        do { _ = try ArchiveService.list(protected7z) } catch { protected7zListingRequiresPassword = true }
        guard protected7zListingRequiresPassword else {
            throw NSError(domain: "ArchiveCheck", code: 32, userInfo: [NSLocalizedDescriptionKey: "Header-encrypted 7z archive listed without its password"])
        }
        let protected7zItems = try ArchiveService.list(protected7z, password: "testpass")
        guard protected7zItems.contains(where: { $0.path == "note.txt" }) else {
            throw NSError(domain: "ArchiveCheck", code: 33, userInfo: [NSLocalizedDescriptionKey: "Correct password did not reveal encrypted 7z archive headers"])
        }
        try ArchiveService.test(protected7z, password: "testpass")
        let protected7zOutput = root.appendingPathComponent("protected-7z-output", isDirectory: true)
        try ArchiveService.extract(protected7zItems, from: protected7z, to: protected7zOutput, password: "testpass")
        guard try Data(contentsOf: protected7zOutput.appendingPathComponent("note.txt")) == Data("archive panel verification".utf8) else {
            throw NSError(domain: "ArchiveCheck", code: 34, userInfo: [NSLocalizedDescriptionKey: "Encrypted 7z extraction changed file contents"])
        }
        let packedSelectionPAK = root.appendingPathComponent("packed-selection.pak")
        _ = try ArchiveService.pack([note], to: packedSelectionPAK, format: .pak, compressionLevel: 5)
        guard try ArchiveService.list(packedSelectionPAK).contains(where: { $0.path == "note.txt" && $0.size == 26 }) else {
            throw NSError(domain: "ArchiveCheck", code: 17, userInfo: [NSLocalizedDescriptionKey: "PAK packing from a virtual archive selection lost its selected file"])
        }

        let queuedArchive = root.appendingPathComponent("queued-fixture.zip")
        try FileManager.default.copyItem(at: archive, to: queuedArchive)
        let queuedDestination = root.appendingPathComponent("queued-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: queuedDestination, withIntermediateDirectories: true)
        let queuedPaths = try await FileTransferQueue.shared.enqueueArchive(
            selections: [ArchiveService.Item(path: "folder/sub/note.txt", size: 26, packedSize: 0, modified: "", isDirectory: false)],
            from: queuedArchive,
            to: queuedDestination,
            move: false,
            collisions: .fail,
            fileMask: nil,
            onlyNonEmptyDirectories: false
        )
        guard queuedPaths == ["folder/sub/note.txt"],
              try Data(contentsOf: queuedDestination.appendingPathComponent("note.txt")) == Data("archive panel verification".utf8) else {
            throw NSError(domain: "ArchiveCheck", code: 14, userInfo: [NSLocalizedDescriptionKey: "queued F5 transfer did not deliver the selected member"])
        }

        let controlledSource = root.appendingPathComponent("controlled-copy.bin")
        try Data(repeating: 0x5A, count: 2 * 1024 * 1024).write(to: controlledSource)
        let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: preservedDate], ofItemAtPath: controlledSource.path)
        let controlledDestination = root.appendingPathComponent("controlled-copy-output", isDirectory: true)
        try FileManager.default.createDirectory(at: controlledDestination, withIntermediateDirectories: true)
        let pauseController = TransferController(totalBytes: 2 * 1024 * 1024)
        pauseController.setSpeedLimit(1024 * 1024)
        let pauseTask = Task.detached(priority: .userInitiated) {
            try FileTransferService.transfer(sources: [controlledSource], to: controlledDestination, move: false, collisions: .fail, controller: pauseController)
        }
        for _ in 0..<200 where pauseController.snapshot.bytesCopied == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard pauseController.snapshot.bytesCopied > 0 else {
            pauseController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 35, userInfo: [NSLocalizedDescriptionKey: "Copy callback did not report data progress"])
        }
        pauseController.setPaused(true)
        let pausedBytes = pauseController.snapshot.bytesCopied
        try await Task.sleep(for: .milliseconds(150))
        guard pauseController.snapshot.paused, pauseController.snapshot.bytesCopied == pausedBytes else {
            pauseController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 39, userInfo: [NSLocalizedDescriptionKey: "Pause did not stop the copy callback from advancing"])
        }
        pauseController.setPaused(false)
        _ = try await pauseTask.value
        let controlledOutput = controlledDestination.appendingPathComponent(controlledSource.lastPathComponent)
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: controlledOutput.path)
        guard try Data(contentsOf: controlledOutput) == Data(contentsOf: controlledSource),
              (outputAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640,
              abs((outputAttributes[.modificationDate] as? Date ?? .distantPast).timeIntervalSince(preservedDate)) < 1 else {
            throw NSError(domain: "ArchiveCheck", code: 36, userInfo: [NSLocalizedDescriptionKey: "Controlled copy failed to preserve bytes, permissions, or modification time"])
        }

        let cancelSource = root.appendingPathComponent("cancel-copy.bin")
        try Data(repeating: 0xA5, count: 2 * 1024 * 1024).write(to: cancelSource)
        let cancelDestination = root.appendingPathComponent("cancel-copy-output", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelDestination, withIntermediateDirectories: true)
        let cancelController = TransferController(totalBytes: 2 * 1024 * 1024)
        cancelController.setSpeedLimit(1024 * 1024)
        let cancelTask = Task.detached(priority: .userInitiated) {
            try FileTransferService.transfer(sources: [cancelSource], to: cancelDestination, move: false, collisions: .fail, controller: cancelController)
        }
        for _ in 0..<200 where cancelController.snapshot.bytesCopied == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard cancelController.snapshot.bytesCopied > 0 else {
            cancelController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 40, userInfo: [NSLocalizedDescriptionKey: "Cancel fixture did not reach its first data callback"])
        }
        cancelController.cancel()
        var cancellationObserved = false
        do { _ = try await cancelTask.value } catch { cancellationObserved = cancelController.snapshot.cancelled }
        guard cancellationObserved,
              FileManager.default.fileExists(atPath: cancelSource.path),
              !FileManager.default.fileExists(atPath: cancelDestination.appendingPathComponent(cancelSource.lastPathComponent).path) else {
            throw NSError(domain: "ArchiveCheck", code: 37, userInfo: [NSLocalizedDescriptionKey: "Cancelled copy did not preserve the source and remove its partial target"])
        }

        let limitedSource = root.appendingPathComponent("limited-copy.bin")
        try Data(repeating: 0x3C, count: 128 * 1024).write(to: limitedSource)
        let limitedDestination = root.appendingPathComponent("limited-copy-output", isDirectory: true)
        try FileManager.default.createDirectory(at: limitedDestination, withIntermediateDirectories: true)
        let speedController = TransferController(totalBytes: 128 * 1024)
        speedController.setSpeedLimit(64 * 1024)
        let speedStartedAt = Date()
        _ = try FileTransferService.transfer(sources: [limitedSource], to: limitedDestination, move: false, collisions: .fail, controller: speedController)
        guard Date().timeIntervalSince(speedStartedAt) >= 1.5 else {
            throw NSError(domain: "ArchiveCheck", code: 38, userInfo: [NSLocalizedDescriptionKey: "64 KiB/s transfer limit was not applied to the copy callback"])
        }

        let processMarker = root.appendingPathComponent("process-resumed")
        let processController = TransferController(totalBytes: 0, operationName: "Archive")
        let controlledProcess = Process()
        controlledProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        controlledProcess.arguments = ["-c", "sleep 1; touch \(processMarker.path)"]
        try controlledProcess.run()
        processController.attachProcess(controlledProcess)
        processController.setPaused(true)
        guard processController.snapshot.backendPaused else {
            processController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 41, userInfo: [NSLocalizedDescriptionKey: "Transfer controller did not suspend its active backend process"])
        }
        try await Task.sleep(for: .milliseconds(1_200))
        guard !FileManager.default.fileExists(atPath: processMarker.path) else {
            processController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 42, userInfo: [NSLocalizedDescriptionKey: "Suspended backend process continued to run"])
        }
        processController.setPaused(false)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: processMarker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        controlledProcess.waitUntilExit()
        processController.detachProcess(controlledProcess)
        guard FileManager.default.fileExists(atPath: processMarker.path) else {
            throw NSError(domain: "ArchiveCheck", code: 43, userInfo: [NSLocalizedDescriptionKey: "Resumed backend process did not finish"])
        }

        let killController = TransferController(totalBytes: 0, operationName: "Archive")
        let longRunningProcess = Process()
        longRunningProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        longRunningProcess.arguments = ["10"]
        try longRunningProcess.run()
        killController.attachProcess(longRunningProcess)
        killController.cancel()
        longRunningProcess.waitUntilExit()
        killController.detachProcess(longRunningProcess)
        guard killController.snapshot.cancelled, !longRunningProcess.isRunning else {
            throw NSError(domain: "ArchiveCheck", code: 44, userInfo: [NSLocalizedDescriptionKey: "Cancelling an active backend process did not terminate it"])
        }

        let deleteArchive = root.appendingPathComponent("delete-fixture.zip")
        try FileManager.default.copyItem(at: archive, to: deleteArchive)
        let deleteModel = FilePaneModel(directory: root)
        guard let deleteEntry = deleteModel.entries.first(where: { $0.name == "delete-fixture.zip" }) else {
            throw NSError(domain: "ArchiveCheck", code: 10, userInfo: [NSLocalizedDescriptionKey: "delete fixture missing from panel"])
        }
        deleteModel.open(deleteEntry)
        guard let folderEntry = deleteModel.entries.first(where: { $0.name == "folder" }) else {
            throw NSError(domain: "ArchiveCheck", code: 11, userInfo: [NSLocalizedDescriptionKey: "delete fixture root listing failed"])
        }
        deleteModel.selectedIDs = [folderEntry.id]
        try deleteModel.deleteSelection()
        guard deleteModel.errorMessage == nil, deleteModel.entries.filter({ !$0.isParent }).isEmpty,
              try ArchiveService.list(deleteArchive).isEmpty else {
            throw NSError(domain: "ArchiveCheck", code: 12, userInfo: [NSLocalizedDescriptionKey: "F8 model operation did not delete the selected directory or refresh an empty archive"])
        }

        let directoryMoveArchive = root.appendingPathComponent("directory-move.zip")
        try FileManager.default.copyItem(at: archive, to: directoryMoveArchive)
        let directoryDestination = root.appendingPathComponent("directory-move-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: true)
        let directoryMoved = try ArchiveTransferService.transfer(
            selections: [ArchiveService.Item(path: "folder", size: 0, packedSize: 0, modified: "", isDirectory: true)],
            from: directoryMoveArchive,
            to: directoryDestination,
            move: true,
            collisions: .fail
        )
        guard directoryMoved == ["folder"],
              try Data(contentsOf: directoryDestination.appendingPathComponent("folder/sub/note.txt")) == Data("archive panel verification".utf8),
              try ArchiveService.list(directoryMoveArchive).isEmpty else {
            throw NSError(domain: "ArchiveCheck", code: 13, userInfo: [NSLocalizedDescriptionKey: "recursive F6 move did not transfer the full directory and remove its archive records"])
        }

        let movedMember = ArchiveService.Item(path: "folder/sub/note.txt", size: 26, packedSize: 0, modified: "", isDirectory: false)
        let moveDestination = root.appendingPathComponent("move-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: moveDestination, withIntermediateDirectories: true)
        let moved = try ArchiveTransferService.transfer(
            selections: [movedMember],
            from: archive,
            to: moveDestination,
            move: true,
            collisions: .fail
        )
        guard moved.count == 1,
              try Data(contentsOf: moveDestination.appendingPathComponent("note.txt")) == Data("archive panel verification".utf8),
              try ArchiveService.list(archive).allSatisfy(\.isDirectory) else {
            throw NSError(domain: "ArchiveCheck", code: 7, userInfo: [NSLocalizedDescriptionKey: "archive move did not preserve destination data and remove the moved member"])
        }
        try ArchiveService.remove([ArchiveService.Item(path: "folder", size: 0, packedSize: 0, modified: "", isDirectory: true)], from: archive)
        let remainingZipItems = try ArchiveService.list(archive)
        guard remainingZipItems.isEmpty else {
            throw NSError(domain: "ArchiveCheck", code: 9, userInfo: [NSLocalizedDescriptionKey: "recursive archive delete left directory records behind"])
        }

        let pak = root.appendingPathComponent("fixture.pak")
        let sourceFile = source.appendingPathComponent("note.txt")
        let pakEntry = FileEntry(url: sourceFile, name: "note.txt", isDirectory: false, byteSize: 26, modifiedAt: nil, attributes: "", isParent: false)
        try PAKArchiveService.pack([pakEntry], to: pak)
        try ArchiveService.test(pak)
        let largePAKSource = root.appendingPathComponent("large-pak-member.bin")
        try Data(repeating: 0x3C, count: 16 * 1024 * 1024).write(to: largePAKSource)
        let largePAK = root.appendingPathComponent("large-member.pak")
        let largePAKEntry = FileEntry(url: largePAKSource, name: "large-pak-member.bin", isDirectory: false, byteSize: 16 * 1024 * 1024, modifiedAt: nil, attributes: "", isParent: false)
        try PAKArchiveService.pack([largePAKEntry], to: largePAK)
        let pakTransferDestination = root.appendingPathComponent("pak-cancel-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: pakTransferDestination, withIntermediateDirectories: true)
        let largePAKItem = try ArchiveService.list(largePAK)[0]
        let pakController = TransferController(totalBytes: largePAKItem.size)
        pakController.setSpeedLimit(1024 * 1024)
        let pakTransfer = Task.detached(priority: .userInitiated) {
            try ArchiveTransferService.transfer(
                selections: [largePAKItem], from: largePAK, to: pakTransferDestination,
                move: false, collisions: .fail, controller: pakController
            )
        }
        for _ in 0..<200 where pakController.snapshot.bytesCopied == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard pakController.snapshot.bytesCopied > 0 else {
            pakController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 42, userInfo: [NSLocalizedDescriptionKey: "PAK extraction did not report progress"])
        }
        pakController.setPaused(true)
        let pausedPAKBytes = pakController.snapshot.bytesCopied
        try await Task.sleep(for: .milliseconds(400))
        guard pakController.snapshot.paused, pakController.snapshot.bytesCopied == pausedPAKBytes else {
            pakController.cancel()
            throw NSError(domain: "ArchiveCheck", code: 43, userInfo: [NSLocalizedDescriptionKey: "PAK extraction did not pause between data chunks"])
        }
        pakController.cancel()
        var pakCancellationObserved = false
        do { _ = try await pakTransfer.value } catch { pakCancellationObserved = pakController.snapshot.cancelled }
        guard pakCancellationObserved,
              !FileManager.default.fileExists(atPath: pakTransferDestination.appendingPathComponent("large-pak-member.bin").path),
              try ArchiveService.list(largePAK).contains(where: { $0.path == "large-pak-member.bin" }) else {
            throw NSError(domain: "ArchiveCheck", code: 44, userInfo: [NSLocalizedDescriptionKey: "Cancelled PAK extraction left output behind or changed the archive"])
        }
        let damagedPAK = root.appendingPathComponent("damaged.pak")
        var damagedPAKData = try Data(contentsOf: pak)
        damagedPAKData[0] = 0
        try damagedPAKData.write(to: damagedPAK)
        var damagedPAKRejected = false
        do { try ArchiveService.test(damagedPAK) } catch { damagedPAKRejected = true }
        guard damagedPAKRejected else {
            throw NSError(domain: "ArchiveCheck", code: 29, userInfo: [NSLocalizedDescriptionKey: "PAK integrity check accepted an invalid signature"])
        }
        try PAKArchiveService.remove(paths: ["note.txt"], from: pak)
        guard try ArchiveService.list(pak).isEmpty else {
            throw NSError(domain: "ArchiveCheck", code: 8, userInfo: [NSLocalizedDescriptionKey: "PAK rewrite did not remove the selected entry"])
        }
        let nestedPAK = root.appendingPathComponent("nested.pak")
        let nestedEntry = FileEntry(url: sourceFile, name: "folder/sub/note.txt", isDirectory: false, byteSize: 26, modifiedAt: nil, attributes: "", isParent: false)
        try PAKArchiveService.pack([nestedEntry], to: nestedPAK)
        let renamePAK = root.appendingPathComponent("rename-nested.pak")
        try FileManager.default.copyItem(at: nestedPAK, to: renamePAK)
        let renamePAKModel = FilePaneModel(directory: root)
        guard let renamePAKEntry = renamePAKModel.entries.first(where: { $0.name == "rename-nested.pak" }) else {
            throw NSError(domain: "ArchiveCheck", code: 24, userInfo: [NSLocalizedDescriptionKey: "nested PAK rename fixture missing from panel"])
        }
        renamePAKModel.open(renamePAKEntry)
        guard let pakFolder = renamePAKModel.entries.first(where: { $0.name == "folder" }) else {
            throw NSError(domain: "ArchiveCheck", code: 25, userInfo: [NSLocalizedDescriptionKey: "nested PAK folder missing from panel"])
        }
        try renamePAKModel.rename([pakFolder], to: ["renamed"])
        guard try ArchiveService.list(renamePAK).contains(where: { $0.path == "renamed/sub/note.txt" }) else {
            throw NSError(domain: "ArchiveCheck", code: 26, userInfo: [NSLocalizedDescriptionKey: "recursive PAK rename failed"])
        }
        let pakMoveDestination = root.appendingPathComponent("pak-move-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: pakMoveDestination, withIntermediateDirectories: true)
        let movedPAKFolder = try ArchiveTransferService.transfer(
            selections: [ArchiveService.Item(path: "folder", size: 0, packedSize: 0, modified: "", isDirectory: true)],
            from: nestedPAK,
            to: pakMoveDestination,
            move: true,
            collisions: .fail
        )
        guard movedPAKFolder == ["folder"],
              try Data(contentsOf: pakMoveDestination.appendingPathComponent("folder/sub/note.txt")) == Data("archive panel verification".utf8),
              try ArchiveService.list(nestedPAK).isEmpty else {
            throw NSError(domain: "ArchiveCheck", code: 18, userInfo: [NSLocalizedDescriptionKey: "recursive move from PAK failed"])
        }
        model.parent()
        model.parent()
        model.parent()
        guard model.archiveURL == nil, model.directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else {
            throw NSError(domain: "ArchiveCheck", code: 6, userInfo: [NSLocalizedDescriptionKey: "parent navigation did not leave archive at its containing folder"])
        }
        print("Archive panel navigation, file/directory/dangling symlink copies, keep-both symlink collisions, ZIP/PAK integrity tests, AES-256 ZIP and header-encrypted 7z creation/list/test/extraction, wrong-password rejection, damaged-archive rejection, pause/resume/cancel for copied data, PAK extraction and active backend processes, partial-file cleanup, metadata-preserving copy, 64 KiB/s rate limiting, ZIP/PAK create and rename, queued F5 copy, F6 file and recursive directory moves, F8 recursive delete, PAK rewrite/removal, empty archives, and parent navigation verified")
    }

    private static func pakEntryForVerification(source: URL) -> FileEntry {
        FileEntry(url: source, name: source.lastPathComponent, isDirectory: false, byteSize: 26, modifiedAt: nil, attributes: "", isParent: false)
    }
}
