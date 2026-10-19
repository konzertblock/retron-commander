import AppKit
import SwiftUI

private struct FTPItem: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct FTPBrowserDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverAddress = "ftp://"
    @State private var username = ""
    @State private var password = ""
    @State private var proxyAddress = ""
    @State private var resumeTransfers = false
    @State private var remotePath = "/"
    @State private var pathDraft = "/"
    @State private var items: [FTPItem] = []
    @State private var selected: Set<String> = []
    @State private var isConnected = false
    @State private var isWorking = false
    @State private var activeTransferController: TransferController?
    @State private var transferPaused = false
    @State private var status = "Enter an FTP or FTPS server address."
    @State private var profiles = FTPProfileService.load()
    @State private var selectedProfileID: UUID?
    @State private var profileName = ""
    @State private var showSaveProfile = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("ftp://server/path", text: $serverAddress).textFieldStyle(.roundedBorder).disabled(isConnected)
                TextField("User", text: $username).textFieldStyle(.roundedBorder).frame(width: 140).disabled(isConnected)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 140).disabled(isConnected)
                Button(isConnected ? "Disconnect" : "Connect") { isConnected ? disconnect() : connect() }
                    .disabled(isWorking)
            }.padding(10)
            HStack(spacing: 8) {
                TextField("Proxy (optional)", text: $proxyAddress).textFieldStyle(.roundedBorder).disabled(isWorking)
                Toggle("Resume transfers", isOn: $resumeTransfers).toggleStyle(.checkbox).frame(width: 155)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            HStack(spacing: 8) {
                Picker("Saved profile", selection: $selectedProfileID) {
                    Text("No profile").tag(Optional<UUID>.none)
                    ForEach(profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                .frame(width: 260)
                .disabled(isConnected || profiles.isEmpty)
                .onChange(of: selectedProfileID) { _, id in if let id { loadProfile(id) } }
                Button("Save Profile…") { profileName = currentProfileName; showSaveProfile = true }
                    .disabled(isConnected || isWorking || serverAddress.trimmingCharacters(in: .whitespacesAndNewlines) == "ftp://")
                Button("Delete") { deleteSelectedProfile() }
                    .disabled(isConnected || isWorking || selectedProfileID == nil)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            HStack {
                Button("Up") { go(to: parentPath(remotePath)) }.disabled(!isConnected || remotePath == "/")
                TextField("Remote directory", text: $pathDraft).textFieldStyle(.roundedBorder).disabled(!isConnected)
                    .onSubmit { go(to: pathDraft) }
                Button("Go") { go(to: pathDraft) }.disabled(!isConnected || isWorking)
                Button("Refresh") { go(to: remotePath) }.disabled(!isConnected || isWorking)
            }.padding(.horizontal, 10).padding(.bottom, 8)
            Table(items, selection: $selected) {
                TableColumn("Remote name", value: \.name)
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Enter folder") {
                    if let name = selected.first { go(to: appendPath(remotePath, component: name)) }
                }.disabled(!isConnected || selected.count != 1 || isWorking)
                Button("Upload…") { upload() }.disabled(!isConnected || isWorking)
                Button(selected.count > 1 ? "Download " + String(selected.count) + "…" : "Download…") { download() }.disabled(!isConnected || selected.isEmpty || isWorking)
                if isWorking {
                    Button(transferPaused ? "Resume" : "Pause") {
                        transferPaused.toggle()
                        activeTransferController?.setPaused(transferPaused)
                    }
                    Button("Cancel transfer") { activeTransferController?.cancel() }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(10)
        }
        .frame(minWidth: 760, minHeight: 500)
        .alert("Save FTP profile", isPresented: $showSaveProfile) {
            TextField("Profile name", text: $profileName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { saveProfile() }
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The password is stored in the macOS Keychain.")
        }
    }

    private var currentProfileName: String {
        profiles.first(where: { $0.id == selectedProfileID })?.name ?? URLComponents(string: serverAddress)?.host ?? "FTP Server"
    }

    private func saveProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existing = profiles.first(where: { $0.id == selectedProfileID && $0.name == name })
        let profile = FTPProfile(
            id: existing?.id ?? UUID(), name: name,
            serverAddress: serverAddress, username: username,
            proxyAddress: proxyAddress, resumeTransfers: resumeTransfers
        )
        do {
            try FTPProfileService.setPassword(password, for: profile)
            let replaced = profiles.filter { $0.id == profile.id || $0.name.caseInsensitiveCompare(name) == .orderedSame }
            for oldProfile in replaced where oldProfile.id != profile.id {
                try FTPProfileService.delete(oldProfile)
            }
            profiles.removeAll { $0.id == profile.id || $0.name.caseInsensitiveCompare(name) == .orderedSame }
            profiles.append(profile)
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            FTPProfileService.save(profiles)
            selectedProfileID = profile.id
            status = "Saved profile \(profile.name)."
        } catch { status = error.localizedDescription }
    }

    private func loadProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        serverAddress = profile.serverAddress
        username = profile.username
        password = FTPProfileService.password(for: profile) ?? ""
        proxyAddress = profile.proxyAddress
        resumeTransfers = profile.resumeTransfers
        status = "Loaded profile \(profile.name)."
    }

    private func deleteSelectedProfile() {
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }
        do {
            try FTPProfileService.delete(profile)
            profiles.removeAll { $0.id == profile.id }
            FTPProfileService.save(profiles)
            selectedProfileID = nil
            status = "Deleted profile \(profile.name)."
        } catch { status = error.localizedDescription }
    }

    private func connect() {
        do {
            let url = try makeURL(path: "/")
            runListing(url, path: "/")
        } catch { status = error.localizedDescription }
    }

    private func disconnect() {
        isConnected = false
        items = []
        selected = []
        password = ""
        status = "Disconnected."
    }

    private func go(to path: String) {
        do { runListing(try makeURL(path: path), path: path) }
        catch { status = error.localizedDescription }
    }

    private func runListing(_ url: URL, path: String) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                let output = try await FTPService.run(url: url, username: username, password: password, proxy: proxyAddress, resume: false, mode: .list)
                let names = output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                items = names.map(FTPItem.init(name:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                selected = []
                remotePath = normalizedPath(path)
                pathDraft = remotePath
                isConnected = true
                status = "\(items.count) entries · \(url.host ?? "") · \(url.scheme?.uppercased() ?? "FTP")"
            } catch {
                if isConnected { status = "Could not list that directory: \(error.localizedDescription)" }
                else { status = error.localizedDescription }
            }
            isWorking = false
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let operations = try panel.urls.map { file -> (TransferController) async throws -> String in
                let target = try makeURL(path: appendPath(remotePath, component: file.lastPathComponent), directory: false)
                return { controller in try await FTPService.run(url: target, username: username, password: password, proxy: proxyAddress, resume: resumeTransfers, mode: .upload(file), controller: controller) }
            }
            performTransfers(operations)
        } catch { status = error.localizedDescription }
    }

    private func download() {
        let names = selected.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return }
        let directoryPanel = NSOpenPanel()
        directoryPanel.canChooseFiles = false
        directoryPanel.canChooseDirectories = true
        directoryPanel.canCreateDirectories = true
        directoryPanel.allowsMultipleSelection = false
        directoryPanel.prompt = "Download Here"
        directoryPanel.message = names.count == 1 ? "Choose a folder for \(names[0])." : "Choose a folder for the selected files."
        guard directoryPanel.runModal() == .OK, let directory = directoryPanel.url else { return }
        do {
            let operations = try names.map { name -> (TransferController) async throws -> String in
                let remote = try makeURL(path: appendPath(remotePath, component: name), directory: false)
                let file = directory.appendingPathComponent(name)
                return { controller in try await FTPService.run(url: remote, username: username, password: password, proxy: proxyAddress, resume: resumeTransfers, mode: .download(file), controller: controller) }
            }
            performTransfers(operations)
        } catch { status = error.localizedDescription }
    }

    private func performTransfers(_ operations: [(TransferController) async throws -> String]) {
        isWorking = true
        transferPaused = false
        let controller = TransferController(totalBytes: 0, operationName: "FTP Transfer")
        activeTransferController = controller
        Task {
            do {
                for (index, operation) in operations.enumerated() {
                    status = operations.count == 1 ? "Transferring…" : "Transfer \(index + 1) of \(operations.count)…"
                    _ = try await operation(controller)
                }
                isWorking = false
                activeTransferController = nil
                status = operations.count == 1 ? "Transfer complete." : "All \(operations.count) transfers complete."
                go(to: remotePath)
            } catch {
                isWorking = false
                let wasCancelled = controller.snapshot.cancelled
                activeTransferController = nil
                transferPaused = false
                status = wasCancelled ? "Transfer cancelled." : error.localizedDescription
            }
        }
    }

    private func makeURL(path: String, directory: Bool = true) throws -> URL {
        guard let components = URLComponents(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["ftp", "ftps"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw FTPError.invalidAddress }
        var target = components
        if directory { target.path = normalizedPath(path) }
        else {
            let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            target.path = clean.isEmpty ? "/" : "/" + clean
        }
        target.query = nil
        target.fragment = nil
        guard let url = target.url else { throw FTPError.invalidAddress }
        return url
    }

    private func normalizedPath(_ path: String) -> String {
        let value = path.hasPrefix("/") ? path : "/" + path
        guard value != "/" else { return value }
        return "/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
    }

    private func appendPath(_ base: String, component: String) -> String {
        let clean = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalizedPath(base + clean)
    }

    private func parentPath(_ path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/") + "/"
    }
}

private enum FTPError: LocalizedError {
    case invalidAddress
    case invalidCredentials
    case invalidProxy
    case cancelled
    case commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a valid ftp:// or ftps:// address without credentials in the URL."
        case .invalidCredentials: "The username or password contains characters that cannot be passed safely to curl."
        case .invalidProxy: "Enter the proxy as a URL such as http://proxy.example:8080."
        case .cancelled: "FTP transfer cancelled."
        case .commandFailed(let detail): detail
        }
    }
}

private enum FTPService {
    enum Mode { case list, upload(URL), download(URL) }

    static func run(url: URL, username: String, password: String, proxy: String, resume: Bool, mode: Mode, controller: TransferController? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard controller?.waitUntilResumed() != false else { throw FTPError.cancelled }
            guard !username.contains("\n"), !username.contains("\r"), !password.contains("\n"), !password.contains("\r") else { throw FTPError.invalidCredentials }
            let trimmedProxy = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
            var cleanProxy = trimmedProxy
            var proxyCredentials: String?
            if !trimmedProxy.isEmpty {
                guard var proxyParts = URLComponents(string: trimmedProxy), ["http", "https", "socks5", "socks5h"].contains(proxyParts.scheme?.lowercased() ?? ""), proxyParts.host != nil else {
                    throw FTPError.invalidProxy
                }
                if let proxyUser = proxyParts.user {
                    let decodedUser = proxyUser.removingPercentEncoding ?? proxyUser
                    let decodedPassword = (proxyParts.password ?? "").removingPercentEncoding ?? (proxyParts.password ?? "")
                    proxyCredentials = "\(decodedUser):\(decodedPassword)"
                    guard !proxyCredentials!.contains("\n"), !proxyCredentials!.contains("\r") else { throw FTPError.invalidProxy }
                    proxyParts.user = nil
                    proxyParts.password = nil
                    guard let url = proxyParts.url else { throw FTPError.invalidProxy }
                    cleanProxy = url.absoluteString
                }
            }
            let credentials = escapeConfig("\(username):\(password)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            var arguments = ["--config", "-", "--fail", "--silent", "--show-error", "--ftp-pasv"]
            if url.scheme?.lowercased() == "ftps" { arguments += ["--ssl-reqd"] }
            if !cleanProxy.isEmpty { arguments += ["--proxy", cleanProxy] }
            switch mode {
            case .list: arguments += ["--list-only", url.absoluteString]
            case .upload(let file):
                controller?.setCurrentName(file.lastPathComponent)
                if resume { arguments += ["--continue-at", "-"] }
                arguments += ["--upload-file", file.path, url.absoluteString]
            case .download(let file):
                controller?.setCurrentName(file.lastPathComponent)
                if resume { arguments += ["--continue-at", "-"] }
                arguments += ["--output", file.path, url.absoluteString]
            }
            process.arguments = arguments
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            controller?.attachProcess(process)
            defer { controller?.detachProcess(process) }
            var config = "user = \"\(credentials)\"\n"
            if let proxyCredentials { config += "proxy-user = \"\(escapeConfig(proxyCredentials))\"\n" }
            input.fileHandleForWriting.write(Data(config.utf8))
            try input.fileHandleForWriting.close()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: result, as: UTF8.self)
            if controller?.snapshot.cancelled == true { throw FTPError.cancelled }
            guard process.terminationStatus == 0 else {
                throw FTPError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "curl exited with status \(process.terminationStatus)." : text)
            }
            return text
        }.value
    }

    private static func escapeConfig(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
