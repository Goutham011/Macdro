import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
    init(model: AppModel, onShowMainWindow: (() -> Void)?) {
        let hosting = NSHostingController(
            rootView: ContentView(model: model, onShowMainWindow: onShowMainWindow)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Macdro"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 380, height: 620))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
