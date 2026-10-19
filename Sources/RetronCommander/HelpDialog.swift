import SwiftUI

struct RetronHelpDialog: View {
    private struct Shortcut: Identifiable {
        let key: String
        let action: String
        var id: String { key }
    }
    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [Shortcut] = [
        .init(key: "F1", action: "Help"), .init(key: "F2", action: "Rename selected item"), .init(key: "F3", action: "View selected item"),
        .init(key: "F4", action: "Open selected item in its associated editor"), .init(key: "F5", action: "Copy to the other panel"),
        .init(key: "F6", action: "Move to the other panel"), .init(key: "F7", action: "Create a directory"), .init(key: "F8", action: "Move selected items to Trash"),
        .init(key: "F9", action: "Open the user menu"), .init(key: "F10", action: "Menu bar"), .init(key: "F11", action: "Connect a network share"),
        .init(key: "F12", action: "Disconnect a network volume"), .init(key: "Ctrl+A", action: "Select all"), .init(key: "Ctrl+D", action: "Unselect all"),
        .init(key: "Ctrl+R", action: "Refresh both panels"), .init(key: "Enter", action: "Open selected file or directory")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Retron Commander Help").font(.headline)
            Text("The two panels operate independently. Select a file in the active panel; copy and move send it to the passive panel.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Table(shortcuts) {
                TableColumn("Key", value: \.key).width(min: 100, ideal: 120)
                TableColumn("Action", value: \.action)
            }
            HStack {
                Text("Plugin availability is listed under Plugins → Plugin Coverage.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 440)
    }
}
