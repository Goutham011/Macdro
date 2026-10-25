import Foundation
import NIOCore

final class ConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maxTotal: Int
    private let maxPerIP: Int
    private var total = 0
    private var countsByIP: [String: Int] = [:]

    init(maxTotal: Int, maxPerIP: Int) {
        self.maxTotal = max(1, maxTotal)
        self.maxPerIP = max(1, maxPerIP)
    }

    func acquire(ip: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let currentForIP = countsByIP[ip, default: 0]
        guard total < maxTotal, currentForIP < maxPerIP else {
            return false
        }
        total += 1
        countsByIP[ip] = currentForIP + 1
        return true
    }

    func release(ip: String) {
        lock.lock()
        defer { lock.unlock() }

        total = max(0, total - 1)
        let next = max(0, countsByIP[ip, default: 0] - 1)
        if next == 0 {
            countsByIP.removeValue(forKey: ip)
        } else {
            countsByIP[ip] = next
        }
    }
}

final class IdleTimeoutHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    let timeout: TimeAmount

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let idle = event as? IdleStateHandler.IdleStateEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch idle {
        case .read, .all:
            context.close(promise: nil)
        case .write:
            context.fireUserInboundEventTriggered(event)
        }
    }
}
