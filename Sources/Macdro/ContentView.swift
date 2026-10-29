import AppKit
import MacdroKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false
    @State private var showingTrustSetup = false
    @State private var settingsController: SettingsWindowController?

    private var easyModeBinding: Binding<Bool> {
        Binding(
            get: { model.easyMode },
            set: { model.setEasyMode($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                VStack(spacing: 16) {
                    if let errorMessage = model.errorMessage ?? model.tlsError {
                        errorCard(errorMessage)
                    }

                    pairingCard
                    dropZone
                    filesSection
                }
                .padding(16)
            }
            .frame(maxHeight: 560)
            Divider().opacity(0.55)
            footer
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $showingTrustSetup, onDismiss: { model.stopCertificateSetup() }) {
            CertificateSetupView(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.62, green: 0.51, blue: 1), Color(red: 0.4, green: 0.24, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("M")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Macdro")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(model.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                model.pickFiles()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Choose files or folders")

            Menu {
                Button("Copy Link", action: model.copyLink)
                    .disabled(model.selectedURL == nil)
                Button("Open Receiver in Browser", action: model.openReceiver)
                Button("Open Received Files", action: model.openReceivedFiles)
                Divider()
                Button("New Session", action: model.startNewSession)
                Divider()
                Toggle("Easy Mode", isOn: easyModeBinding)
                Button("Settings…", action: openSettings)
                Divider()
                Button("Quit Macdro") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var pairingCard: some View {
        VStack(spacing: 12) {
            if model.status == .failed {
                ContentUnavailableView {
                    Label("Server unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(model.errorMessage ?? "Macdro could not start its local server.")
                }
                .frame(height: 180)
            } else if !model.isLANAvailable || model.connectionOptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Connect a network")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Join Wi-Fi, plug in Ethernet, or enable USB tethering on your phone.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    Button("Check again", action: model.refreshNetworkNow)
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(height: 184)
            } else if let url = model.selectedURL, let qr = QRCode.image(for: url.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 184, height: 184)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )

                VStack(spacing: 4) {
                    Text("Scan with your phone")
                        .font(.system(size: 13, weight: .semibold))
                    Text(connectionHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if model.isLANAvailable {
                        Text(trustHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(model.easyMode ? "LAN unavailable · local browser only" : "LAN HTTPS unavailable · local browser only")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 8) {
                    if model.connectionOptions.count > 1 {
                        Menu {
                            ForEach(model.connectionOptions) { option in
                                Button {
                                    model.selectConnection(option)
                                } label: {
                                    Label(
                                        "\(option.label) · \(option.address.ipAddress)",
                                        systemImage: transportIcon(for: option)
                                    )
                                }
                            }
                        } label: {
                            Label(model.connectionLabel, systemImage: selectedTransportIcon)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Label(model.connectionLabel, systemImage: selectedTransportIcon)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        model.copyLink()
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if !model.easyMode {
                        Button {
                            model.startCertificateSetup()
                            showingTrustSetup = true
                        } label: {
                            Label("Trust", systemImage: "checkmark.shield")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(!model.isLANAvailable)
                    }
                }
                .padding(.horizontal, 4)
            } else {
                ProgressView()
                    .frame(height: 184)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .background(.background.opacity(0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var dropZone: some View {
        Button {
            model.pickFiles()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: model.isAddingFiles ? "hourglass" : "arrow.down.doc")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text(model.isAddingFiles ? "Adding files…" : "Drop files or folders here")
                    .font(.system(size: 12, weight: .semibold))
                Text("Files stay on this Mac until your phone downloads them")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var filesSection: some View {
        if !model.files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.files.count == 1 ? "1 FILE" : "\(model.files.count) FILES")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.7)
                    Spacer()
                    Text(FileFormatting.bytes(model.totalBytes))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 2)

                VStack(spacing: 1) {
                    ForEach(model.files) { file in
                        fileRow(file)
                    }
                }
                .background(.background.opacity(0.25), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }

    private func fileRow(_ file: SharedFile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: iconName(for: file))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text([FileFormatting.bytes(file.size), file.relativePath == file.name ? nil : file.relativePath]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                model.remove(file)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop sharing \(file.name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack {
            Text(model.easyMode ? "Local · HTTP (easy mode) · resumable" : "Local · HTTPS · resumable")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("New Session", action: model.startNewSession)
                .font(.system(size: 10.5, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var connectionHint: String {
        guard let transport = model.selectedConnection?.transport else {
            return model.easyMode ? "Plain HTTP · no certificate needed" : "Encrypted HTTPS · no app required"
        }
        switch transport {
        case .usbTethering:
            return model.easyMode ? "USB tethering · no certificate needed" : "USB tethering · no Wi-Fi needed"
        case .wifi:
            return model.easyMode ? "Wi-Fi · no certificate needed" : "Wi-Fi · same network"
        case .ethernet:
            return model.easyMode ? "Ethernet · no certificate needed" : "Ethernet · same network"
        case .unknown:
            return model.easyMode ? "LAN · no certificate needed · no app required" : "LAN · encrypted HTTPS · no app required"
        }
    }

    private var trustHint: String {
        if model.easyMode {
            return "No certificate needed · just open the link"
        }
        return model.tlsFingerprint == nil ? "Preparing certificate…" : "Install Macdro trust first if prompted"
    }

    private func openSettings() {
        if let settingsController {
            NSApp.activate(ignoringOtherApps: true)
            settingsController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(model: model) {
            settingsController = nil
        }
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private var selectedTransportIcon: String {
        transportIcon(for: model.selectedConnection)
    }

    private func transportIcon(for option: NetworkInterfaces.ConnectionOption?) -> String {
        guard let option else { return "wifi" }
        switch option.transport {
        case .usbTethering:
            return "cable.connector"
        case .wifi:
            return "wifi"
        case .ethernet, .unknown:
            return "network"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .starting:
            return .orange
        case .failed:
            return .red
        case .ready:
            return .green
        }
    }

    private func iconName(for file: SharedFile) -> String {
        switch file.contentType {
        case let type where type.hasPrefix("image/"):
            return "photo"
        case let type where type.hasPrefix("video/"):
            return "film"
        case let type where type.hasPrefix("audio/"):
            return "waveform"
        case "application/zip", "application/x-zip-compressed":
            return "archivebox"
        case "application/pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }

                guard let url else { return }
                Task { @MainActor in
                    model.addFiles([url])
                }
            }
        }
        return accepted
    }
}
