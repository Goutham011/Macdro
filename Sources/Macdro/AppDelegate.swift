import AppKit
import Combine
import SwiftUI

private enum LaunchKeys {
    static let launchCount = "launchCount"
    static let hasCompletedWelcome = "hasCompletedWelcome"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitor: Any?
    private var welcomeWindowController: WelcomeWindowController?
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Macdro"
            button.imageScaling = .scaleProportionallyDown
        }
        statusItem = item

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(model: model, onShowMainWindow: { [weak self] in
                self?.showMainWindowFromPopover()
            })
        )
        popover.contentSize = NSSize(width: 380, height: 620)

        updateStatusItem()
        announceLaunch()

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func announceLaunch() {
        let defaults = UserDefaults.standard
        let launchCount = defaults.integer(forKey: LaunchKeys.launchCount) + 1
        defaults.set(launchCount, forKey: LaunchKeys.launchCount)
        NSLog("Macdro launch count=%d welcomeSeen=%d", launchCount, defaults.bool(forKey: LaunchKeys.hasCompletedWelcome) ? 1 : 0)

        if defaults.bool(forKey: LaunchKeys.hasCompletedWelcome) {
            showMainWindow()
        } else {
            showWelcomeWindow()
        }
    }

    private func showMainWindow() {
        let controller: MainWindowController
        if let existing = mainWindowController {
            controller = existing
        } else {
            controller = MainWindowController(model: model, onShowMainWindow: nil)
            mainWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSLog(
            "Macdro main window shown visibleWindows=%@",
            NSApp.windows.filter(\.isVisible).map(\.title).joined(separator: ",") as NSString
        )
    }

    private func showMainWindowFromPopover() {
        closePopover()
        showMainWindow()
    }

    private func showWelcomeWindow() {
        NSLog("Macdro showing welcome window")
        let controller = WelcomeWindowController(
            model: model,
            onOpen: { [weak self] in
                self?.dismissWelcomeWindow()
                self?.showMainWindow()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            },
            onClose: { [weak self] in
                self?.dismissWelcomeWindow()
                self?.showMainWindow()
            }
        )
        welcomeWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSLog(
            "Macdro welcome shown visibleWindows=%@",
            NSApp.windows.filter(\.isVisible).map(\.title).joined(separator: ",") as NSString
        )
    }

    private func dismissWelcomeWindow() {
        guard let controller = welcomeWindowController else { return }
        welcomeWindowController = nil
        UserDefaults.standard.set(true, forKey: LaunchKeys.hasCompletedWelcome)
        if controller.window?.isVisible == true {
            controller.close()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(
            systemSymbolName: model.menuBarIcon,
            accessibilityDescription: "Macdro"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installEventMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeEventMonitor()
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
