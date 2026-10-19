import AppKit
import Network
import SwiftUI

private struct SMBService: Identifiable, Hashable {
    let name: String
    let domain: String
    var id: String { "\(name).\(domain)" }
}

@MainActor
private final class SMBDiscovery: ObservableObject {
    @Published private(set) var services: [SMBService] = []
    @Published private(set) var state = "Searching the local network for SMB servers…"
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                let found = results.compactMap { result -> SMBService? in
                    guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
                    return SMBService(name: name, domain: domain)
                }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                self?.services = found
                self?.state = found.isEmpty ? "No SMB servers were found on the local network." : "\(found.count) SMB server(s) found."
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state { self?.state = "Network discovery failed: \(error.localizedDescription)" }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() { browser?.cancel(); browser = nil }
}

struct NetworkNeighborhoodDialog: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = SMBDiscovery()
    @State private var selected: String?
    @State private var manualAddress = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Network Neighborhood").font(.headline)
                Spacer()
                Button("Refresh") { discovery.stop(); discovery.start() }
            }
            Text(discovery.state).font(.caption).foregroundStyle(.secondary)
            List(discovery.services, selection: $selected) { server in
                Label(server.id, systemImage: "network")
                    .tag(server.id)
                    .contextMenu { Button("Connect in Finder") { connect(server) } }
            }.frame(minHeight: 200)
            HStack {
                Button("Connect in Finder") {
                    if let selected, let service = discovery.services.first(where: { $0.id == selected }) { connect(service) }
                }.disabled(selected == nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            Text("Connect to a known SMB server").font(.subheadline).fontWeight(.semibold)
            HStack {
                TextField("smb://server/share", text: $manualAddress).textFieldStyle(.roundedBorder)
                Button("Open") { connect(manualAddress) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .frame(width: 560, height: 450)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func connect(_ service: SMBService) {
        let host = service.name.contains(".") ? service.name : "\(service.name).\(service.domain)"
        connect("smb://\(host)/")
    }

    private func connect(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "smb", url.host != nil else {
            error = "Enter a valid smb:// server or share address."
            return
        }
        guard NSWorkspace.shared.open(url) else { error = "macOS could not open the network share."; return }
        dismiss()
    }
}
