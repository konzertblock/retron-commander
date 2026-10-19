import Foundation

enum UserMenuCommand {
    static func expand(
        _ template: String,
        selectedItems: [URL],
        activeDirectory: URL,
        inactiveDirectory: URL,
        leftItems: [URL],
        rightItems: [URL],
        leftDirectory: URL,
        rightDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let items = selectedItems.isEmpty ? [activeDirectory] : selectedItems
        let allNames = items.map { shellQuote($0.path) }.joined(separator: " ")
        let compares = [
            "FileOrDirToCompareLeft": leftItems.first,
            "FileOrDirToCompareRight": rightItems.first,
            "FileOrDirToCompareActive": leftDirectory == activeDirectory ? leftItems.first : rightItems.first,
            "FileOrDirToCompareInactive": leftDirectory == activeDirectory ? rightItems.first : leftItems.first,
            "FileToCompareLeft": leftItems.first(where: { !isDirectory($0) }),
            "FileToCompareRight": rightItems.first(where: { !isDirectory($0) }),
            "FileToCompareActive": (leftDirectory == activeDirectory ? leftItems : rightItems).first(where: { !isDirectory($0) }),
            "FileToCompareInactive": (leftDirectory == activeDirectory ? rightItems : leftItems).first(where: { !isDirectory($0) }),
            "DirToCompareLeft": leftItems.first(where: isDirectory),
            "DirToCompareRight": rightItems.first(where: isDirectory),
            "DirToCompareActive": (leftDirectory == activeDirectory ? leftItems : rightItems).first(where: isDirectory),
            "DirToCompareInactive": (leftDirectory == activeDirectory ? rightItems : leftItems).first(where: isDirectory)
        ]

        let runOnce = template.contains("$(ListOfSelectedNames)") || compares.keys.contains(where: template.contains)
        let contexts = runOnce ? [items.first ?? activeDirectory] : items
        return contexts.map { item in
            var command = template
            let parent = item.deletingLastPathComponent()
            let name = item.lastPathComponent
            let nameURL = URL(fileURLWithPath: name)
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop", isDirectory: true)
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Documents", isDirectory: true)
            let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Library", isDirectory: true)
            let values: [String: String] = [
                "FullName": shellQuote(item.path),
                "Drive": shellQuote(volumeRoot(for: item).path),
                "Path": shellQuote(parent.path),
                "Name": shellQuote(name),
                "NamePart": shellQuote(nameURL.deletingPathExtension().lastPathComponent),
                "ExtPart": shellQuote(nameURL.pathExtension),
                "FullPath": shellQuote(parent.path),
                "FullPathInactive": shellQuote(inactiveDirectory.path),
                "FullPathLeft": shellQuote(leftDirectory.path),
                "FullPathRight": shellQuote(rightDirectory.path),
                "ListOfSelectedNames": allNames,
                // Native path variables replace the Windows-directory and DOS
                // short-name concepts with useful macOS locations. DOS 8.3 aliases
                // have no stable macOS equivalent and are intentionally not emulated.
                "MacHome": shellQuote(home.path),
                "MacTemp": shellQuote(fileManager.temporaryDirectory.path),
                "MacDesktop": shellQuote(desktop.path),
                "MacDocuments": shellQuote(documents.path),
                "MacDownloads": shellQuote(downloads.path),
                "MacLibrary": shellQuote(library.path),
                "MacApplicationSupport": shellQuote(appSupport.path),
                "MacApplications": shellQuote("/Applications"),
                "MacSystem": shellQuote("/System"),
                "MacAppBundle": shellQuote(Bundle.main.bundleURL.path)
            ]
            for (key, value) in values { command = command.replacingOccurrences(of: "$(\(key))", with: value) }
            for (key, value) in compares {
                let token = "$(\(key))"
                command = command.replacingOccurrences(of: token, with: value.map { shellQuote($0.path) } ?? "")
            }
            command = expandEnvironmentVariables(in: command, environment: environment)
            return command
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func volumeRoot(for url: URL) -> URL {
        if let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume { return volume }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    private static func expandEnvironmentVariables(in command: String, environment: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\$\[([A-Za-z_][A-Za-z0-9_]*)\]"#) else { return command }
        let nsCommand = command as NSString
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: nsCommand.length)).reversed()
        var result = command
        for match in matches {
            let name = nsCommand.substring(with: match.range(at: 1))
            guard let value = environment[name] else { continue }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: shellQuote(value))
            }
        }
        return result
    }
}
