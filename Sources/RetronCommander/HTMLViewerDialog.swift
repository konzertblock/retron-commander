import SwiftUI
import WebKit

struct HTMLViewerDialog: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Reload") { reloadToken += 1 }
                Button("Open in Browser") { NSWorkspace.shared.open(file) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            HTMLWebView(file: file)
                .id(reloadToken)
                .background(Color.white)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct HTMLWebView: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
