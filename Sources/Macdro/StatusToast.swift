import AppKit
import SwiftUI

struct StatusToastView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.5, green: 0.36, blue: 0.97))
            Text("Macdro is running in the menu bar")
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }
}

@MainActor
final class StatusToastController {
    private var window: NSWindow?

    func show(below button: NSButton) {
        close()
        guard let buttonWindow = button.window else { return }

        let hosting = NSHostingController(rootView: StatusToastView())
        let toastWindow = NSWindow(contentViewController: hosting)
        toastWindow.styleMask = [.borderless]
        toastWindow.isOpaque = false
        toastWindow.backgroundColor = .clear
        toastWindow.hasShadow = true
        toastWindow.ignoresMouseEvents = true
        toastWindow.level = .statusBar
        toastWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toastWindow.isReleasedWhenClosed = false

        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        let buttonRect = buttonWindow.convertToScreen(button.frame)
        var origin = NSPoint(
            x: buttonRect.midX - size.width / 2,
            y: buttonRect.minY - size.height - 8
        )
        let screen = buttonWindow.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        }
        toastWindow.setFrame(NSRect(origin: origin, size: size), display: true)
        toastWindow.orderFrontRegardless()
        window = toastWindow
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
