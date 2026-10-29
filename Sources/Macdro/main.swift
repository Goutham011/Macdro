import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = delegate
    application.run()
}
