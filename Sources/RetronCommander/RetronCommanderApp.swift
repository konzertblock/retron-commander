import SwiftUI
import Sparkle

@main
struct RetronCommanderApp: App {
    @NSApplicationDelegateAdaptor(RetronApplicationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let updaterController: SPUStandardUpdaterController
    private let updatesAreConfigured: Bool

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = info["SUFeedURL"] as? String
        let publicKey = info["SUPublicEDKey"] as? String
        let configured = feedURL?.hasPrefix("https://") == true && !(publicKey?.isEmpty ?? true)
        updatesAreConfigured = configured
        updaterController = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup("Retron Commander", id: "main") {
            MainWindowView()
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    appDelegate.reopenMainWindow = { openWindow(id: "main") }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            RetronCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    guard updatesAreConfigured else { return }
                    updaterController.checkForUpdates(nil)
                }
                .disabled(!updatesAreConfigured)
            }
        }
    }
}

@MainActor
private final class RetronApplicationDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        reopenMainWindow?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct RetronCommands: Commands {
    var body: some Commands {
        CommandMenu("Left") {
            Button("Go to Parent") { sendRetronCommand("left-parent") }
            Button("Refresh") { sendRetronCommand("refresh") }
        }
        CommandMenu("Files") {
            Button("Rename…") { sendRetronCommand("rename") }
            Button("View") { sendRetronCommand("view") }
            Button("Edit") { sendRetronCommand("edit") }
            Divider()
            Button("Copy…") { sendRetronCommand("copy") }
            Button("Move…") { sendRetronCommand("move") }
            Button("Create Folder…") { sendRetronCommand("mkdir") }
            Button("Move to Trash") { sendRetronCommand("delete") }
            Divider()
            Button("Pack…") { sendRetronCommand("pack") }
            Button("Unpack…") { sendRetronCommand("unpack") }
            Button("Batch Rename…") { sendRetronCommand("batch-rename") }
            Button("Split / Combine…") { sendRetronCommand("split") }
            Button("Properties…") { sendRetronCommand("properties") }
            Button("Calculate Checksums…") { sendRetronCommand("checksums") }
            Button("Decode MIME…") { sendRetronCommand("mime") }
            Button("View DBF Table…") { sendRetronCommand("dbf") }
            Button("View Multimedia Information…") { sendRetronCommand("multimedia") }
            Button("Encrypt / Decrypt…") { sendRetronCommand("encrypt") }
        }
        CommandMenu("Edit") {
            Button("Select All") { sendRetronCommand("select-all") }.keyboardShortcut("a", modifiers: [.control])
            Button("Deselect All") { sendRetronCommand("deselect-all") }.keyboardShortcut("d", modifiers: [.control])
            Button("Restore Selection") { sendRetronCommand("restore-selection") }
            Button("Invert Selection") { sendRetronCommand("invert-selection") }
            Button("Select Using Masks…") { sendRetronCommand("select-mask") }
            Button("Unselect Using Masks…") { sendRetronCommand("unselect-mask") }
        }
        CommandMenu("Commands") {
            Button("Find Files…") { sendRetronCommand("search") }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Compare Directories") { sendRetronCommand("compare") }
            Button("Compare Selected Files") { sendRetronCommand("compare-files") }
            Button("Disk Map…") { sendRetronCommand("disk-map") }
            Button("Find Duplicates…") { sendRetronCommand("duplicates") }
            Button("Calculate Space Occupied…") { sendRetronCommand("selected-size") }
            Button("Calculate Directory Sizes") { sendRetronCommand("directory-sizes") }
            Button("Swap Panels") { sendRetronCommand("swap") }
            Button("Refresh Both Panels") { sendRetronCommand("refresh") }
            Divider()
            Button("User Menu…") { sendRetronCommand("user-menu") }
            Button("Connect Network…") { sendRetronCommand("connect") }
            Button("Disconnect Network…") { sendRetronCommand("disconnect") }
            Button("Network Neighborhood…") { sendRetronCommand("network") }
            Button("Restore from Trash…") { sendRetronCommand("trash") }
        }
        CommandMenu("Plugins") {
            Button("Plugin Coverage…") { sendRetronCommand("plugin-coverage") }
            Button("Run Automation Script…") { sendRetronCommand("automation") }
            Button("Open Selected Archive…") { sendRetronCommand("archive") }
            Button("Disk Image Browser…") { sendRetronCommand("disk-image") }
            Button("FTP Client…") { sendRetronCommand("ftp") }
            Button("Portable Executable Viewer…") { sendRetronCommand("pe") }
            Button("Property List Editor…") { sendRetronCommand("plist") }
            Button("Export Multimedia Info to HTML…") { sendRetronCommand("multimedia-export") }
            Button("Restore from Trash…") { sendRetronCommand("trash") }
        }
        CommandMenu("Options") {
            Button("Show / Hide Hidden Files") { sendRetronCommand("hidden") }
            Button("Add Active Folder to Hot Paths") { sendRetronCommand("hot-path") }
            Button("Settings…") { sendRetronCommand("settings") }.keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Right") {
            Button("Go to Parent") { sendRetronCommand("right-parent") }
            Button("Refresh") { sendRetronCommand("refresh") }
        }
        CommandMenu("Help") {
            Button("Retron Commander Help") { sendRetronCommand("help") }
        }
    }
}
