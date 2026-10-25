import Foundation
import Network

public final class NetworkPathMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.macdro.path-monitor")
    private let onChange: @Sendable () -> Void
    private var hasStarted = false

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        monitor.pathUpdateHandler = { [onChange] _ in
            onChange()
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
