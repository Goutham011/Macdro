import AppKit
import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let onOpen: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
                    Text("Welcome to Macdro")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 15) {
                step(
                    icon: "menubar.rectangle",
                    title: "It lives in the menu bar",
                    text: "Macdro runs quietly in the background. Click its icon in the top-right menu bar any time."
                )
                step(
                    icon: "qrcode",
                    title: "Pair your phone",
                    text: "Open the menu-bar popover and scan the QR code with your phone camera — no app to install."
                )
                step(
                    icon: "checkmark.shield",
                    title: "Trust once",
                    text: "The first time your phone connects over HTTPS, install the Macdro profile it asks for."
                )
            }
            .padding(18)

            Divider().opacity(0.55)

            HStack {
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Macdro", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .frame(width: 410)
        .background(.regularMaterial)
    }

    private func step(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(red: 0.5, green: 0.36, blue: 0.97))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        model: AppModel,
        onOpen: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let hosting = NSHostingController(
            rootView: WelcomeView(model: model, onOpen: onOpen, onQuit: onQuit)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Macdro"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        NSLog("Macdro welcome window closed")
        onClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSLog("Macdro welcome became key frame=%@", NSStringFromRect(window?.frame ?? .zero))
    }
}
