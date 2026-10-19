import Foundation

enum CommandRunner {
    static func run(_ command: String, in directory: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()

            // Drain while the process runs so large command output cannot fill
            // the pipe and block the child.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if process.terminationStatus != 0 && text.isEmpty {
                return "Command exited with status \(process.terminationStatus)."
            }
            return text.isEmpty ? "Command completed (status \(process.terminationStatus))." : text
        }.value
    }
}
