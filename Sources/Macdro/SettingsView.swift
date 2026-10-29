import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    private var easyModeBinding: Binding<Bool> {
        Binding(
            get: { model.easyMode },
            set: { model.setEasyMode($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .font(.system(size: 11.5))
            }

            Toggle(isOn: easyModeBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Easy mode — no certificate required")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Phones open the receiver directly: no certificate to install and no browser warnings. Files and the link are not encrypted in transit beyond your Wi-Fi. Leave this off for encrypted HTTPS transfers.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Text(model.easyMode
                ? "Current: phone transfers use plain HTTP (easy mode)."
                : "Current: phone transfers use encrypted HTTPS with the Macdro certificate.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(model.easyMode ? Color.orange : Color.green)

            Text("Applies to phone and LAN connections only. The Mac's own browser connection stays local either way.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private final class CloseBox {
        var close: () -> Void = {}
    }

    private let onClose: () -> Void
    private let closeBox: CloseBox

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let box = CloseBox()
        self.closeBox = box
        let hosting = NSHostingController(
            rootView: SettingsView(model: model, onDone: { box.close() })
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Macdro Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        box.close = { [weak self] in
            self?.window?.performClose(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        NSLog("Macdro settings window closed")
        onClose()
    }
}
