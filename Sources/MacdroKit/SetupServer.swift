import Foundation
import Logging
@preconcurrency import NIOCore
import NIOHTTP1
import NIOPosix

public final class MacdroSetupServer {
    public enum SetupError: LocalizedError {
        case couldNotBind(underlying: Error)
        case alreadyStopped

        public var errorDescription: String? {
            switch self {
            case .couldNotBind:
                return "Could not start the certificate setup server."
            case .alreadyStopped:
                return "The certificate setup server has already stopped. Open the trust setup again."
            }
        }
    }

    private let identityManager: TLSIdentityManager
    private let lifetime: TimeInterval
    private let logger: Logger
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: Channel?
    private var stopTask: Scheduled<Void>?
    private var hasShutDown = false
    private var isShuttingDown = false
    private let stateLock = NSLock()

    public private(set) var port: Int = 0

    public init(
        identityManager: TLSIdentityManager,
        lifetime: TimeInterval = 5 * 60,
        logger: Logger = Logger(label: "macdro.setup")
    ) {
        self.identityManager = identityManager
        self.lifetime = lifetime
        self.logger = logger
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return channel?.isActive == true
    }

    @discardableResult
    public func start(host: String = "0.0.0.0", preferredPort: Int = 0) throws -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let channel, channel.isActive {
            return port
        }
        guard !hasShutDown, !isShuttingDown else {
            throw SetupError.alreadyStopped
        }

        do {
            let identity = try identityManager.identity(for: NetworkInterfaces.ipv4Addresses().map(\.ipAddress))
            let handler = SetupHTTPHandler(identity: identity)
            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
                .bind(host: host, port: preferredPort)
                .wait()

            self.channel = channel
            self.port = channel.localAddress?.port ?? preferredPort
            scheduleStopLocked()
            logger.info("Certificate setup listening on \(host):\(port)")
            return port
        } catch {
            throw SetupError.couldNotBind(underlying: error)
        }
    }

    public func stop() {
        stateLock.lock()
        stopTask?.cancel()
        stopTask = nil
        guard !isShuttingDown else {
            stateLock.unlock()
            return
        }
        isShuttingDown = true
        let runningChannel = channel
        channel = nil
        stateLock.unlock()

        guard let runningChannel else {
            completeShutdown()
            return
        }
        runningChannel.close().whenComplete { [weak self] _ in
            self?.completeShutdown()
        }
    }

    private func completeShutdown() {
        stateLock.lock()
        guard !hasShutDown else {
            stateLock.unlock()
            return
        }
        hasShutDown = true
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async { [group] in
            try? group.syncShutdownGracefully()
        }
    }

    private func scheduleStopLocked() {
        stopTask?.cancel()
        guard let channel else { return }
        stopTask = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(lifetime * 1000))) { [weak self] in
            self?.stop()
        }
    }
}

private final class SetupHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let identity: TLSIdentity
    private var head: HTTPRequestHead?

    init(identity: TLSIdentity) {
        self.identity = identity
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head else { return }
            self.head = nil
            route(head: head, context: context)
        }
    }

    private func route(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let remote = context.channel.remoteAddress?.ipAddress,
              NetworkInterfaces.isAllowedRemote(remote)
        else {
            respond(context, head, status: .forbidden, type: "text/plain; charset=utf-8", body: Data("Forbidden\n".utf8))
            return
        }

        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        guard head.method == .GET || head.method == .HEAD else {
            respond(context, head, status: .methodNotAllowed, type: "text/plain; charset=utf-8", body: Data("Method not allowed\n".utf8))
            return
        }

        switch path {
        case "/", "/setup", "/setup/":
            respond(context, head, status: .ok, type: "text/html; charset=utf-8", body: setupPage())
        case "/ca.crt":
            respond(
                context,
                head,
                status: .ok,
                type: "application/x-x509-ca-cert",
                body: Data(identity.caCertificatePEM.utf8),
                extraHeaders: [("Content-Disposition", "attachment; filename=\"Macdro-Local-CA.crt\"")]
            )
        case "/ca.mobileconfig":
            respond(
                context,
                head,
                status: .ok,
                type: "application/x-apple-aspen-config",
                body: identity.mobileConfiguration,
                extraHeaders: [("Content-Disposition", "attachment; filename=\"Macdro-Local-Network.mobileconfig\"")]
            )
        case "/health":
            respond(context, head, status: .ok, type: "text/plain; charset=utf-8", body: Data("ok\n".utf8))
        default:
            respond(context, head, status: .notFound, type: "text/plain; charset=utf-8", body: Data("Not found\n".utf8))
        }
    }

    private func setupPage() -> Data {
        let fingerprint = identity.fingerprint
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Trust Macdro</title>
        <style>
        :root{color-scheme:dark light}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:34rem;margin:0 auto;padding:2rem 1.25rem;line-height:1.5}
        code{overflow-wrap:anywhere;background:rgba(127,127,127,.15);padding:.5rem;border-radius:.5rem;display:block}
        a.button{display:inline-block;margin:.4rem .4rem .4rem 0;padding:.7rem 1rem;border-radius:.65rem;background:#5b3df5;color:#fff;text-decoration:none}
        .note{opacity:.72;font-size:.92rem}
        </style>
        </head>
        <body>
        <h1>Trust Macdro</h1>
        <p>Install the Macdro local certificate authority, then return to the QR code link. This setup server stops automatically in a few minutes.</p>
        <p><a class="button" href="/ca.mobileconfig">Install on iPhone or iPad</a><a class="button" href="/ca.crt">Download CA certificate</a></p>
        <h2>Verify this fingerprint</h2>
        <code>\(escapeHTML(fingerprint))</code>
        <p class="note">The fingerprint must match the one shown in Macdro on your Mac. On iPhone or iPad, after installing the profile, enable full trust under Settings → General → About → Certificate Trust Settings. On Android, install the certificate as a CA certificate under Security → Encryption &amp; credentials.</p>
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func respond(
        _ context: ChannelHandlerContext,
        _ request: HTTPRequestHead,
        status: HTTPResponseStatus,
        type: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: type)
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")
        if type.hasPrefix("text/html") {
            headers.add(
                name: "Content-Security-Policy",
                value: "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
            )
        }
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        if !request.isKeepAlive {
            headers.add(name: "Connection", value: "close")
        }
        let response = HTTPResponseHead(version: request.version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        if request.method != .HEAD, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let future = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if !request.isKeepAlive {
            let contextBound = NIOLoopBound(context, eventLoop: context.eventLoop)
            future.whenComplete { _ in
                contextBound.value.close(promise: nil)
            }
        }
    }
}
