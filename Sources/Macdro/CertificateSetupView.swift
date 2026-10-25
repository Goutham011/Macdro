import AppKit
import MacdroKit
import SwiftUI

struct CertificateSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trust Macdro")
                        .font(.system(size: 16, weight: .semibold))
                    Text("This setup page stops automatically after five minutes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let setupURL = model.setupURL, let qr = QRCode.image(for: setupURL.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 176, height: 176)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(setupURL.absoluteString)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let connection = model.selectedConnection {
                    Text("Using \(connection.label) · \(connection.address.ipAddress)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Copy setup link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(setupURL.absoluteString, forType: .string)
                    }
                    Button("Open setup page") {
                        NSWorkspace.shared.open(setupURL)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Connect a network first")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Join Wi-Fi, plug in Ethernet, or enable USB tethering on your phone, then try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Button("Try again") {
                        model.refreshNetworkNow()
                        model.startCertificateSetup()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .frame(height: 176)
            }

            if let fingerprint = model.tlsFingerprint {
                VStack(spacing: 4) {
                    Text("CERTIFICATE FINGERPRINT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.7)
                    Text(fingerprint)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("iPhone or iPad")
                    .font(.system(size: 12, weight: .semibold))
                Text("Open the setup link, install the profile, then enable full trust in Settings > General > About > Certificate Trust Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Android")
                    .font(.system(size: 12, weight: .semibold))
                Text("Open the setup link and install the CA certificate under Security > Encryption & credentials > Install a certificate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18)
        .frame(width: 380)
    }
}
