import AppKit
import Foundation
import MacdroKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Status {
        case starting
        case ready
        case failed
    }

    @Published private(set) var urls: [URL] = []
    @Published private(set) var files: [SharedFile] = []
    @Published private(set) var status: Status = .starting
    @Published private(set) var isAddingFiles = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var setupURL: URL?
    @Published private(set) var tlsFingerprint: String?
    @Published private(set) var caFingerprint: String?
    @Published private(set) var tlsError: String?
    @Published private(set) var connectionOptions: [NetworkInterfaces.ConnectionOption] = []
    @Published var selectedURL: URL?

    let store = SessionStore()

    private var server: MacdroServer?
    private var setupServer: MacdroSetupServer?
    private var port = 0
    private var lanPort = 0
    private var networkRefreshTask: Task<Void, Never>?
    private var pathMonitor: NetworkPathMonitor?
    private var networkRefreshDebounceTask: Task<Void, Never>?

    init() {
        startServer()
    }

    var menuBarIcon: String {
        switch status {
        case .starting:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle"
        case .ready:
            return files.isEmpty ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill"
        }
    }

    var totalBytes: UInt64 {
        files.reduce(0) { $0 + $1.size }
    }

    var statusText: String {
        switch status {
        case .starting:
            return "Starting…"
        case .failed:
            return "Server unavailable"
        case .ready:
            return files.isEmpty ? "Ready for files" : "Sharing"
        }
    }

    var connectionLabel: String {
        guard let connection = selectedConnection else {
            return selectedURL?.host ?? "No network"
        }
        return "\(connection.label) · \(connection.address.ipAddress)"
    }

    var localURL: URL? {
        server?.localURLBase
    }

    var isLANAvailable: Bool {
        lanPort > 0
    }

    var selectedConnection: NetworkInterfaces.ConnectionOption? {
        NetworkInterfaces.preferredConnection(
            from: connectionOptions,
            matching: selectedURL?.host
        )
    }

    func addFiles(_ incoming: [URL]) {
        guard !incoming.isEmpty else { return }
        isAddingFiles = true
        errorMessage = nil

        Task {
            let expanded = await Task.detached(priority: .userInitiated) {
                SharedFileExpander.expand(urls: incoming)
            }.value

            store.add(expanded)
            syncFiles()

            if expanded.isEmpty {
                errorMessage = "No readable files were found."
            }
            isAddingFiles = false
        }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose files or folders to share"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    func remove(_ file: SharedFile) {
        store.remove(id: file.id)
        syncFiles()
    }

    func startNewSession() {
        store.removeAll()
        _ = store.rotateToken()
        syncFiles()
        refreshNetworkURLs()
    }

    func startCertificateSetup() {
        guard let connection = selectedConnection else {
            errorMessage = "Connect this Mac to Wi-Fi, Ethernet, or USB tethering before setting up phone trust."
            return
        }
        setupServer?.stop()
        if let server {
            do {
                try server.refreshTLSIdentity()
                tlsError = server.lanError?.localizedDescription
            } catch {
                tlsError = error.localizedDescription
            }
        }
        setupServer = MacdroSetupServer(identityManager: server?.tlsIdentityManager ?? TLSIdentityManager())
        do {
            let setupPort = try setupServer?.start(
                host: connection.address.ipAddress,
                identity: server?.tlsIdentity
            ) ?? 0
            setupURL = connection.setupURL(port: setupPort)
            tlsFingerprint = server?.tlsFingerprint
            caFingerprint = server?.caFingerprint
        } catch {
            errorMessage = error.localizedDescription
            setupURL = nil
        }
    }

    func stopCertificateSetup() {
        setupServer?.stop()
        setupServer = nil
        setupURL = nil
    }

    func selectConnection(_ connection: NetworkInterfaces.ConnectionOption) {
        guard let url = urls.first(where: { $0.host == connection.address.ipAddress }) else {
            return
        }
        selectedURL = url
    }

    func refreshNetworkNow() {
        refreshNetworkURLs()
    }

    func copyLink() {
        guard let url = selectedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func openReceiver() {
        guard let localURL else { return }
        NSWorkspace.shared.open(localURL)
    }

    func openReceivedFiles() {
        let directory = MacdroServer.defaultUploadDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func startServer() {
        do {
            let server = MacdroServer(store: store)
            port = try server.start()
            lanPort = server.lanPort
            tlsFingerprint = server.tlsFingerprint
            caFingerprint = server.caFingerprint
            tlsError = server.lanError?.localizedDescription
            self.server = server
            status = .ready
            refreshNetworkURLs()
            startNetworkObservation()
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
        }
    }

    private func startNetworkObservation() {
        pathMonitor?.cancel()
        pathMonitor = NetworkPathMonitor { [weak self] in
            Task { @MainActor in
                self?.scheduleNetworkRefresh()
            }
        }
        pathMonitor?.start()

        networkRefreshTask?.cancel()
        networkRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.refreshNetworkURLs()
            }
        }
    }

    private func scheduleNetworkRefresh() {
        networkRefreshDebounceTask?.cancel()
        networkRefreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNetworkURLs()
        }
    }

    private func refreshNetworkURLs() {
        guard let server else { return }

        do {
            try server.refreshTLSIdentity()
            tlsError = server.lanError?.localizedDescription
        } catch {
            tlsError = error.localizedDescription
        }
        lanPort = server.lanPort
        tlsFingerprint = server.tlsFingerprint
        caFingerprint = server.caFingerprint

        let token = store.token
        let options = NetworkInterfaces.connectionOptions()
        connectionOptions = options
        var newURLs: [URL] = []
        if lanPort > 0 {
            newURLs = options.compactMap { option in
                URL(string: "https://\(option.address.ipAddress):\(lanPort)/s/\(token)/")
            }
        }
        if newURLs.isEmpty, let local = server.localURLBase {
            newURLs = [local]
        }

        urls = newURLs
        if let selectedURL, newURLs.contains(selectedURL) {
            return
        }
        selectedURL = newURLs.first
    }

    private func syncFiles() {
        files = store.snapshot().files
    }
}
