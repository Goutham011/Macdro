import Foundation

final class RequestRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var buckets: [String: [Date]] = [:]

    func allow(key: String, limit: Int, interval: TimeInterval) -> Bool {
        guard limit > 0 else { return false }
        let now = Date()
        let cutoff = now.addingTimeInterval(-interval)

        lock.lock()
        defer { lock.unlock() }

        var timestamps = buckets[key, default: []].filter { $0 >= cutoff }
        guard timestamps.count < limit else {
            buckets[key] = timestamps
            return false
        }
        timestamps.append(now)
        buckets[key] = timestamps
        if buckets.count > 2_048 {
            buckets = buckets.filter { !$0.value.allSatisfy { $0 < cutoff } }
        }
        return true
    }
}

final class SingleFlight<Value>: @unchecked Sendable {
    typealias Completion = (Result<Value, Error>) -> Void

    private let lock = NSLock()
    private var pending: [String: [Completion]] = [:]

    func run(
        key: String,
        work: @escaping () -> Result<Value, Error>,
        completion: @escaping Completion
    ) {
        lock.lock()
        if pending[key] != nil {
            pending[key]?.append(completion)
            lock.unlock()
            return
        }
        pending[key] = [completion]
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let result = work()
            self.lock.lock()
            let completions = self.pending.removeValue(forKey: key) ?? []
            self.lock.unlock()
            for callback in completions {
                callback(result)
            }
        }
    }
}
