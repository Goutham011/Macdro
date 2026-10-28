import Foundation
import Logging
@preconcurrency import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

public enum MacdroServerError: LocalizedError {
    case couldNotBind(host: String, port: Int, underlying: Error)
    case webAssetsMissing

    public var errorDescription: String? {
        switch self {
        case .couldNotBind(let host, let port, _):
            return "Could not start the transfer server on \(host):\(port)."
        case .webAssetsMissing:
            return "The embedded receiver web assets are missing."
        }
    }
}

public struct MacdroServerConfiguration: Sendable {
    public var maxBufferedBodyBytes: Int
    public var readTimeoutSeconds: Int
    public var maxConnections: Int
    public var maxConnectionsPerIP: Int
    public var upload: UploadStore.Configuration
    public var identityDirectory: URL?

    public init(
        maxBufferedBodyBytes: Int = MacdroLimits.maxBufferedBodyBytes,
        readTimeoutSeconds: Int = MacdroLimits.readTimeoutSeconds,
        maxConnections: Int = MacdroLimits.maxConnections,
        maxConnectionsPerIP: Int = MacdroLimits.maxConnectionsPerIP,
        upload: UploadStore.Configuration = UploadStore.Configuration(),
        identityDirectory: URL? = nil
    ) {
        self.maxBufferedBodyBytes = maxBufferedBodyBytes
        self.readTimeoutSeconds = readTimeoutSeconds
        self.maxConnections = maxConnections
        self.maxConnectionsPerIP = maxConnectionsPerIP
        self.upload = upload
        self.identityDirectory = identityDirectory
    }
}

public final class MacdroServer {
    private let store: SessionStore
    private let uploadStore: UploadStore
    private let lanHost: String
    private let loopbackHost: String
    private let preferredPort: Int
    private let webRoot: URL
    private let logger: Logger
    private let configuration: MacdroServerConfiguration
    private let connectionGate: ConnectionGate
    private let rateLimiter = RequestRateLimiter()
    private let manifestService = ManifestService()
    private let archiveService = ArchiveService()
    private let group: MultiThreadedEventLoopGroup
    private let ioPool: NIOThreadPool
    private var loopbackChannel: Channel?
    private var lanChannel: Channel?
    private var hasShutDown = false

    public let tlsIdentityManager: TLSIdentityManager
    public private(set) var port: Int = 0
    public private(set) var lanPort: Int = 0
    public private(set) var tlsIdentity: TLSIdentity?
    public private(set) var lanError: Error?

    public var isRunning: Bool {
        loopbackChannel?.isActive == true
    }

    public var isLANRunning: Bool {
        lanChannel?.isActive == true
    }

    public var localURLBase: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://\(loopbackHost):\(port)/s/\(store.token)/")
    }

    public var lanURLBase: URL? {
        guard lanPort > 0 else { return nil }
        return URL(string: "https://\(NetworkInterfaces.primaryIPv4()?.ipAddress ?? lanHost):\(lanPort)/s/\(store.token)/")
    }

    public var tlsFingerprint: String? {
        tlsIdentity?.fingerprint
    }

    public var caFingerprint: String? {
        tlsIdentity?.caFingerprint
    }

    public static var defaultUploadDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Macdro", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Downloads/Macdro", isDirectory: true)
    }

    public init(
        store: SessionStore,
        host: String = "0.0.0.0",
        port: Int = 8787,
        webRoot: URL? = nil,
        uploadDirectory: URL = MacdroServer.defaultUploadDirectory,
        configuration: MacdroServerConfiguration = MacdroServerConfiguration(),
        logger: Logger = Logger(label: "macdro.server")
    ) {
        self.store = store
        self.uploadStore = UploadStore(
            directory: uploadDirectory,
            configuration: configuration.upload
        )
        self.lanHost = host
        self.loopbackHost = Self.isLoopback(host) ? host : "127.0.0.1"
        self.preferredPort = port
        self.configuration = configuration
        self.connectionGate = ConnectionGate(
            maxTotal: configuration.maxConnections,
            maxPerIP: configuration.maxConnectionsPerIP
        )
        self.logger = logger
        self.tlsIdentityManager = TLSIdentityManager(directory: configuration.identityDirectory)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.ioPool = NIOThreadPool(numberOfThreads: max(2, System.coreCount / 2))
        self.ioPool.start()

        if let webRoot {
            self.webRoot = webRoot
        } else if let embedded = Bundle.module.url(forResource: "Web", withExtension: nil) {
            self.webRoot = embedded
        } else {
            self.webRoot = URL(fileURLWithPath: "/nonexistent-macdro-web-assets")
            logger.error("Embedded web assets were not found")
        }
    }

    @discardableResult
    public func start() throws -> Int {
        if let loopbackChannel, loopbackChannel.isActive {
            return port
        }

        let candidates = preferredPort == 0 ? [0] : Array(preferredPort...(preferredPort + 20))
        var lastError: Error?
        for candidate in candidates {
            do {
                let channel = try makeBootstrap(secure: false, sslContext: nil)
                    .bind(host: loopbackHost, port: candidate)
                    .wait()
                loopbackChannel = channel
                port = channel.localAddress?.port ?? candidate
                logger.info("Macdro receiver listening on http://\(loopbackHost):\(port)")
                break
            } catch {
                lastError = error
            }
        }

        guard loopbackChannel != nil else {
            throw MacdroServerError.couldNotBind(
                host: loopbackHost,
                port: preferredPort,
                underlying: lastError ?? MacdroServerError.webAssetsMissing
            )
        }

        guard !Self.isLoopback(lanHost) else {
            return port
        }

        startLANListener(candidates: candidates)
        return port
    }

    public func refreshTLSIdentity() throws {
        guard !Self.isLoopback(lanHost) else { return }
        let identity = try tlsIdentityManager.identity(
            for: NetworkInterfaces.ipv4Addresses().map(\.ipAddress)
        )
        guard tlsIdentity?.fingerprint != identity.fingerprint || lanChannel == nil else {
            tlsIdentity = identity
            return
        }
        if let lanChannel {
            try? lanChannel.close().wait()
            self.lanChannel = nil
            lanPort = 0
        }
        let candidates = preferredPort == 0 ? [0] : Array(preferredPort...(preferredPort + 20))
        startLANListener(candidates: candidates)
    }

    private func startLANListener(candidates: [Int]) {
        do {
            let identity = try tlsIdentityManager.identity(
                for: NetworkInterfaces.ipv4Addresses().map(\.ipAddress)
            )
            let sslContext = try identity.makeContext()
            tlsIdentity = identity
            var tlsError: Error?
            for candidate in candidates where candidate != port {
                do {
                    let channel = try makeBootstrap(secure: true, sslContext: sslContext)
                        .bind(host: lanHost, port: candidate)
                        .wait()
                    lanChannel = channel
                    lanPort = channel.localAddress?.port ?? candidate
                    lanError = nil
                    logger.info("Macdro receiver listening on https://\(lanHost):\(lanPort)")
                    return
                } catch {
                    tlsError = error
                }
            }
            lanError = tlsError
            logger.error("LAN TLS listener unavailable: \(String(describing: tlsError))")
        } catch {
            lanError = error
            logger.error("LAN TLS identity unavailable: \(error)")
        }
    }

    public func stop() {
        if let channel = lanChannel {
            try? channel.close().wait()
            lanChannel = nil
        }
        if let channel = loopbackChannel {
            try? channel.close().wait()
            loopbackChannel = nil
        }
        guard !hasShutDown else { return }
        hasShutDown = true
        archiveService.removeAll()
        try? ioPool.syncShutdownGracefully()
        try? group.syncShutdownGracefully()
    }

    private func makeBootstrap(secure: Bool, sslContext: NIOSSLContext?) -> ServerBootstrap {
        let store = self.store
        let uploadStore = self.uploadStore
        let webRoot = self.webRoot
        let logger = self.logger
        let configuration = self.configuration
        let connectionGate = self.connectionGate
        let rateLimiter = self.rateLimiter
        let manifestService = self.manifestService
        let archiveService = self.archiveService
        let ioPool = self.ioPool
        let readTimeout = TimeAmount.seconds(Int64(max(1, configuration.readTimeoutSeconds)))

        var decoderLimits = NIOHTTPDecoderLimitConfiguration()
        decoderLimits.maxHeaderFieldSize = MacdroLimits.maxHeaderFieldSize
        decoderLimits.maxHeaderListSize = MacdroLimits.maxHeaderListSize
        decoderLimits.maxHeaderFieldCount = MacdroLimits.maxHeaderFieldCount

        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_KEEPALIVE), value: 1)
            .childChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelInitializer { channel in
                let ip = channel.remoteAddress?.ipAddress ?? "unknown"
                guard connectionGate.acquire(ip: ip) else {
                    return channel.close()
                }
                channel.closeFuture.whenComplete { _ in
                    connectionGate.release(ip: ip)
                }

                do {
                    try channel.pipeline.syncOperations.addHandler(
                        IdleStateHandler(allTimeout: readTimeout)
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        IdleTimeoutHandler(timeout: readTimeout)
                    )
                    if secure, let sslContext {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: sslContext)
                        )
                    }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withErrorHandling: true,
                        withEncoderConfiguration: .init(),
                        withDecoderLimitConfiguration: decoderLimits
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        MacdroHTTPHandler(
                            store: store,
                            uploadStore: uploadStore,
                            webRoot: webRoot,
                            logger: logger,
                            ioPool: ioPool,
                            rateLimiter: rateLimiter,
                            manifestService: manifestService,
                            archiveService: archiveService,
                            maxBufferedBodyBytes: configuration.maxBufferedBodyBytes,
                            headerTimeoutSeconds: configuration.readTimeoutSeconds,
                            isSecure: secure
                        )
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
