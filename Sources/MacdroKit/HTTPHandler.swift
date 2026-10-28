import AppKit
import Darwin
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

final class MacdroHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: SessionStore
    private let uploadStore: UploadStore
    private let webRoot: URL
    private let logger: Logger
    private let ioPool: NIOThreadPool
    private let maxBufferedBodyBytes: Int
    private let isSecure: Bool
    private var clientID = "unknown"
    private let rateLimiter: RequestRateLimiter
    private let manifestService: ManifestService
    private let archiveService: ArchiveService
    private let maxPendingUploadBytes = MacdroLimits.maxPendingUploadBytes
    private let resumeUploadBytes = 4 * 1024 * 1024
    private let uploadCoalesceBytes = MacdroLimits.uploadCoalesceBytes
    private let maxRejectedBodyDrainBytes = MacdroLimits.maxRejectedBodyDrainBytes
    private let headerTimeoutSeconds: Int

    private var headerTimeoutTask: Scheduled<Void>?
    private var isStreamingResponse = false
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer
    private var upload: UploadTransaction?
    private var uploadFailure: UploadFailure?
    private var uploadID: String?
    private var resumable = false
    private var completeUpload = false
    private var isRejectingRequest = false
    private var rejectedBodyBytes = 0
    private var uploadWriteTail: EventLoopFuture<Void>?
    private var uploadWriteError: Error?
    private var uploadBuffer = Data()
    private var pendingUploadBytes = 0
    private var readsPaused = false
    private var isFinalizingUpload = false
    private var sseTask: RepeatedTask?
    private var sseLastSignature = ""
    private var sseAuthGeneration: UInt64 = 0
    private var sseStartedAt = Date()
    private var sseLastWrite = Date()
    private var resumableLeaseID: String?

    private struct UploadFailure {
        let status: HTTPResponseStatus
        let message: String
        var headers: [(String, String)] = []
    }

    init(
        store: SessionStore,
        uploadStore: UploadStore,
        webRoot: URL,
        logger: Logger,
        ioPool: NIOThreadPool,
        rateLimiter: RequestRateLimiter,
        manifestService: ManifestService,
        archiveService: ArchiveService,
        maxBufferedBodyBytes: Int = MacdroLimits.maxBufferedBodyBytes,
        headerTimeoutSeconds: Int = MacdroLimits.readTimeoutSeconds,
        isSecure: Bool = false
    ) {
        self.store = store
        self.uploadStore = uploadStore
        self.webRoot = webRoot
        self.logger = logger
        self.ioPool = ioPool
        self.rateLimiter = rateLimiter
        self.manifestService = manifestService
        self.archiveService = archiveService
        self.maxBufferedBodyBytes = max(0, maxBufferedBodyBytes)
        self.headerTimeoutSeconds = max(1, headerTimeoutSeconds)
        self.isSecure = isSecure
        self.requestBody = ByteBufferAllocator().buffer(capacity: 0)
    }

    func channelActive(context: ChannelHandlerContext) {
        clientID = context.channel.remoteAddress?.ipAddress ?? "unknown"
        armHeaderTimeout(context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            cancelHeaderTimeout()
            isStreamingResponse = false
            releaseResumableLease()
            requestHead = head
            requestBody.clear()
            upload = nil
            uploadFailure = nil
            uploadID = nil
            resumable = false
            completeUpload = false
            isRejectingRequest = false
            rejectedBodyBytes = 0
            uploadWriteTail = nil
            uploadWriteError = nil
            uploadBuffer.removeAll(keepingCapacity: true)
            pendingUploadBytes = 0
            readsPaused = false
            isFinalizingUpload = false
            prepareUpload(head: head, context: context)

            if upload == nil,
               let declared = head.headers.first(name: "Content-Length").flatMap(UInt64.init),
               declared > UInt64(maxBufferedBodyBytes)
            {
                rejectOversizedBody(head: head, context: context)
            }
        case .body(var body):
            if isRejectingRequest {
                rejectedBodyBytes += body.readableBytes
                if rejectedBodyBytes > maxRejectedBodyDrainBytes {
                    context.close(promise: nil)
                }
                return
            }
            if let upload {
                if let uploadID {
                    uploadStore.touchResumable(id: uploadID)
                }
                bufferUploadBody(Data(body.readableBytesView), upload: upload, context: context)
            } else if uploadFailure == nil {
                if requestBody.readableBytes + body.readableBytes > maxBufferedBodyBytes {
                    if let head = requestHead {
                        rejectOversizedBody(head: head, context: context)
                    }
                    return
                }
                requestBody.writeBuffer(&body)
            }
        case .end:
            defer { armHeaderTimeout(context) }
            if isRejectingRequest {
                isRejectingRequest = false
                rejectedBodyBytes = 0
                requestHead = nil
                context.close(promise: nil)
                return
            }
            guard let head = requestHead else { return }
            requestHead = nil

            if let upload {
                flushUploadBuffer(upload: upload, context: context)
                let wasResumable = resumable
                let shouldComplete = completeUpload
                let id = uploadID
                let tail = uploadWriteTail ?? context.eventLoop.makeSucceededVoidFuture()
                self.upload = nil
                requestBody.clear()
                uploadID = nil
                resumable = false
                completeUpload = false
                isFinalizingUpload = true
                pauseReads(context)
                finishUpload(
                    upload,
                    tail: tail,
                    wasResumable: wasResumable,
                    shouldComplete: shouldComplete,
                    id: id,
                    context: context,
                    request: head
                )
                return
            }

            if let failure = uploadFailure {
                uploadFailure = nil
                requestBody.clear()
                uploadID = nil
                resumable = false
                completeUpload = false
                respond(
                    context: context,
                    request: head,
                    status: failure.status,
                    contentType: "text/plain; charset=utf-8",
                    body: Data(failure.message.utf8),
                    extraHeaders: failure.headers
                )
                return
            }

            let body = requestBody
            requestBody.clear()
            route(head: head, body: body, context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelHeaderTimeout()
        sseTask?.cancel()
        sseTask = nil
        cancelUploadIfNeeded(context: context)
        resetTransferState()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cancelHeaderTimeout()
        cancelUploadIfNeeded(context: context)
        resetTransferState()
        logger.error("HTTP connection error: \(error)")
        context.close(promise: nil)
    }

    private func armHeaderTimeout(_ context: ChannelHandlerContext) {
        cancelHeaderTimeout()
        let timeout = TimeAmount.seconds(Int64(headerTimeoutSeconds))
        headerTimeoutTask = context.eventLoop.scheduleTask(in: timeout) { [weak self, context] in
            guard let self, context.channel.isActive else { return }
            self.sendRequestTimeout(context: context)
        }
    }

    private func cancelHeaderTimeout() {
        headerTimeoutTask?.cancel()
        headerTimeoutTask = nil
    }

    private func sendRequestTimeout(context: ChannelHandlerContext) {
        guard context.channel.isActive,
              !isRejectingRequest,
              !isFinalizingUpload,
              !isStreamingResponse,
              sseTask == nil
        else {
            return
        }
        guard requestHead != nil else {
            context.close(promise: nil)
            return
        }
        requestHead = nil
        requestBody.clear()
        isRejectingRequest = true
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "no-store")
        let response = HTTPResponseHead(version: .http1_1, status: .requestTimeout, headers: headers)
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func releaseResumableLease() {
        guard let id = resumableLeaseID else { return }
        resumableLeaseID = nil
        uploadStore.releaseLease(id: id)
    }

    private func resetTransferState() {
        upload = nil
        uploadFailure = nil
        uploadID = nil
        resumable = false
        completeUpload = false
        uploadWriteTail = nil
        uploadWriteError = nil
        uploadBuffer.removeAll(keepingCapacity: true)
        pendingUploadBytes = 0
        readsPaused = false
        isFinalizingUpload = false
    }

    private func cancelUploadIfNeeded(context: ChannelHandlerContext) {
        guard let upload else { return }
        uploadBuffer.removeAll(keepingCapacity: true)
        if resumable {
            guard !isFinalizingUpload else { return }
            let leaseID = resumableLeaseID
            let tail = uploadWriteTail ?? context.eventLoop.makeSucceededVoidFuture()
            tail.whenComplete { [weak self] _ in
                guard let self, let leaseID else { return }
                self.uploadStore.releaseLease(id: leaseID)
                self.resumableLeaseID = nil
            }
            return
        }
        let tail = uploadWriteTail ?? context.eventLoop.makeSucceededVoidFuture()
        let ioPool = self.ioPool
        tail.whenComplete { _ in
            ioPool.runIfActive(eventLoop: context.eventLoop) {
                upload.cancel()
            }.whenFailure { _ in
                upload.cancel()
            }
        }
    }

    private func bufferUploadBody(
        _ data: Data,
        upload: UploadTransaction,
        context: ChannelHandlerContext
    ) {
        uploadBuffer.append(data)
        pendingUploadBytes += data.count
        if pendingUploadBytes > maxPendingUploadBytes {
            pauseReads(context)
        }
        if uploadBuffer.count >= uploadCoalesceBytes {
            flushUploadBuffer(upload: upload, context: context)
        }
    }

    private func flushUploadBuffer(
        upload: UploadTransaction,
        context: ChannelHandlerContext
    ) {
        guard !uploadBuffer.isEmpty else { return }
        let data = uploadBuffer
        uploadBuffer.removeAll(keepingCapacity: true)
        enqueueUploadBody(data, upload: upload, context: context)
    }

    private func enqueueUploadBody(
        _ data: Data,
        upload: UploadTransaction,
        context: ChannelHandlerContext
    ) {
        let eventLoop = context.eventLoop
        let previous = uploadWriteTail ?? eventLoop.makeSucceededVoidFuture()
        let future = previous.flatMap { [ioPool] in
            ioPool.runIfActive(eventLoop: eventLoop) {
                try upload.append(data)
            }
        }
        uploadWriteTail = future
        future.whenComplete { [weak self] result in
            guard let self else { return }
            self.pendingUploadBytes = max(0, self.pendingUploadBytes - data.count)
            if case .failure(let error) = result {
                self.uploadWriteError = error
            }
            if self.pendingUploadBytes <= self.resumeUploadBytes {
                self.resumeReads(context)
            }
        }
    }

    private func finishUpload(
        _ upload: UploadTransaction,
        tail: EventLoopFuture<Void>,
        wasResumable: Bool,
        shouldComplete: Bool,
        id: String?,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        tail.whenComplete { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.handleUploadFailure(
                    error,
                    upload: upload,
                    wasResumable: wasResumable,
                    id: id,
                    context: context,
                    request: request
                )
            case .success:
                if wasResumable, !shouldComplete {
                    self.respondUploadChunk(upload, context: context, request: request) {
                        self.releaseResumableLease()
                        self.completeUploadResponse(context: loopBoundContext.value)
                    }
                    return
                }

                self.ioPool.runIfActive(eventLoop: context.eventLoop) {
                    try upload.finish()
                }.whenComplete { [weak self] finishResult in
                    guard let self else { return }
                    switch finishResult {
                    case .success(let value):
                        if wasResumable, let id {
                            self.uploadStore.completeResumable(id: id, offset: value.size)
                        }
                        self.releaseResumableLease()
                        self.respondUpload(value, context: context, request: request) {
                            self.completeUploadResponse(context: loopBoundContext.value)
                        }
                    case .failure(let error):
                        if wasResumable, let id {
                            self.uploadStore.failResumable(id: id)
                        }
                        self.releaseResumableLease()
                        self.logger.error("Upload failed: \(error)")
                        self.respondUploadError(error, context: context, request: request) {
                            self.completeUploadResponse(context: loopBoundContext.value)
                        }
                    }
                }
            }
        }
    }

    private func handleUploadFailure(
        _ error: Error,
        upload: UploadTransaction,
        wasResumable: Bool,
        id: String?,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        logger.error("Upload failed: \(error)")
        if wasResumable, let id {
            uploadStore.failResumable(id: id)
            releaseResumableLease()
        } else {
            ioPool.runIfActive(eventLoop: context.eventLoop) {
                upload.cancel()
            }.whenFailure { _ in
                upload.cancel()
            }
        }
        respondUploadError(error, context: context, request: request) {
            self.completeUploadResponse(context: context)
        }
    }

    private func respondUploadError(
        _ error: Error,
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        onComplete: (() -> Void)? = nil
    ) {
        respond(
            context: context,
            request: request,
            status: uploadErrorStatus(error),
            contentType: "text/plain; charset=utf-8",
            body: Data(uploadErrorMessage(error).utf8),
            extraHeaders: uploadFailure(for: error).headers,
            onComplete: onComplete
        )
    }

    private func completeUploadResponse(context: ChannelHandlerContext) {
        uploadBuffer.removeAll(keepingCapacity: true)
        pendingUploadBytes = 0
        isFinalizingUpload = false
        resumeReads(context)
    }

    private func pauseReads(_ context: ChannelHandlerContext) {
        guard !readsPaused else { return }
        readsPaused = true
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
    }

    private func resumeReads(_ context: ChannelHandlerContext) {
        guard readsPaused, !isFinalizingUpload, pendingUploadBytes <= resumeUploadBytes else {
            return
        }
        readsPaused = false
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    private func route(head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext) {
        guard let remoteIP = context.channel.remoteAddress?.ipAddress,
              NetworkInterfaces.isAllowedRemote(remoteIP)
        else {
            respond(
                context: context,
                request: head,
                status: .forbidden,
                contentType: "text/plain; charset=utf-8",
                body: Data("Forbidden\n".utf8)
            )
            return
        }

        let path = pathComponent(of: head.uri)
        let segments = path.split(separator: "/").map(String.init)

        if path == "/health" || path == "/health/" {
            respond(
                context: context,
                request: head,
                status: .ok,
                contentType: "text/plain; charset=utf-8",
                body: Data("ok\n".utf8)
            )
            return
        }

        if path == "/" {
            serveLanding(context: context, request: head)
            return
        }

        if path == "/api/session", head.method == .GET || head.method == .HEAD {
            guard cookieAuthorized(head) else {
                unauthorized(context: context, request: head)
                return
            }
            serveSessionJSON(context: context, request: head)
            return
        }

        if path == "/api/manifest", head.method == .GET || head.method == .HEAD {
            guard cookieAuthorized(head) else {
                unauthorized(context: context, request: head)
                return
            }
            guard allowRateLimit(scope: "manifest", limit: MacdroLimits.manifestRateLimitPerMinute, head: head, context: context) else {
                return
            }
            serveManifest(context: context, request: head)
            return
        }

        if path == "/api/zip", head.method == .GET || head.method == .HEAD {
            guard cookieAuthorized(head) else {
                unauthorized(context: context, request: head)
                return
            }
            guard allowRateLimit(scope: "zip", limit: MacdroLimits.zipRateLimitPerMinute, head: head, context: context) else {
                return
            }
            serveArchive(context: context, request: head)
            return
        }

        if path == "/api/events", head.method == .GET {
            guard cookieAuthorized(head) else {
                unauthorized(context: context, request: head)
                return
            }
            startEventStream(context: context, request: head)
            return
        }

        if path == "/api/clipboard" {
            guard cookieAuthorized(head) else {
                unauthorized(context: context, request: head)
                return
            }
            guard allowRateLimit(scope: "clipboard", limit: MacdroLimits.clipboardRateLimitPerMinute, head: head, context: context) else {
                return
            }
            handleClipboard(head: head, body: body, context: context)
            return
        }

        if segments.count == 2,
           segments[0] == "f",
           let id = UUID(uuidString: segments[1]),
           let file = store.file(id: id)
        {
            guard cookieAuthorized(head) else {
                unauthorized(context: context, request: head)
                return
            }
            serveFile(file, context: context, request: head)
            return
        }

        guard segments.count >= 2,
              segments[0] == "s",
              constantTimeEquals(segments[1], store.token)
        else {
            notFound(context: context, request: head)
            return
        }

        let rest = Array(segments.dropFirst(2))

        if rest.isEmpty, !path.hasSuffix("/") {
            redirect(context: context, request: head, to: "/s/\(store.token)/")
            return
        }

        if rest.isEmpty || rest == ["index.html"] {
            serveWebAsset(
                "index.html",
                contentType: "text/html; charset=utf-8",
                context: context,
                request: head,
                extraHeaders: [("Set-Cookie", sessionCookieHeader)]
            )
            return
        }

        if rest == ["app.js"] {
            serveWebAsset("app.js", contentType: "text/javascript; charset=utf-8", context: context, request: head)
            return
        }

        if rest == ["styles.css"] {
            serveWebAsset("styles.css", contentType: "text/css; charset=utf-8", context: context, request: head)
            return
        }

        if rest == ["favicon.ico"] {
            respond(context: context, request: head, status: .noContent, contentType: "image/x-icon", body: Data())
            return
        }

        if rest == ["api", "session"], head.method == .GET || head.method == .HEAD {
            serveSessionJSON(context: context, request: head)
            return
        }

        if rest == ["api", "manifest"], head.method == .GET || head.method == .HEAD {
            guard allowRateLimit(scope: "manifest", limit: MacdroLimits.manifestRateLimitPerMinute, head: head, context: context) else {
                return
            }
            serveManifest(context: context, request: head)
            return
        }

        if rest == ["api", "zip"], head.method == .GET || head.method == .HEAD {
            guard allowRateLimit(scope: "zip", limit: MacdroLimits.zipRateLimitPerMinute, head: head, context: context) else {
                return
            }
            serveArchive(context: context, request: head)
            return
        }

        if rest == ["api", "events"], head.method == .GET {
            startEventStream(context: context, request: head)
            return
        }

        if rest == ["api", "clipboard"] {
            guard allowRateLimit(scope: "clipboard", limit: MacdroLimits.clipboardRateLimitPerMinute, head: head, context: context) else {
                return
            }
            handleClipboard(head: head, body: body, context: context)
            return
        }

        if rest.count == 2,
           rest[0] == "f",
           let id = UUID(uuidString: rest[1]),
           let file = store.file(id: id)
        {
            serveFile(file, context: context, request: head)
            return
        }

        notFound(context: context, request: head)
    }

    private func prepareUpload(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = pathComponent(of: head.uri)
        let segments = path.split(separator: "/").map(String.init)
        let tokenPath = segments.count == 4
            && segments[0] == "s"
            && segments[2] == "api"
            && segments[3] == "upload"
        let cookiePath = path == "/api/upload" || path == "/api/upload/"
        guard tokenPath || cookiePath else {
            return
        }

        guard head.method == .PUT || head.method == .POST else {
            failUploadPreparation(
                status: .methodNotAllowed,
                message: "Use PUT or POST to upload files.\n",
                head: head,
                context: context
            )
            return
        }

        guard let remoteIP = context.channel.remoteAddress?.ipAddress,
              NetworkInterfaces.isAllowedRemote(remoteIP)
        else {
            failUploadPreparation(
                status: .forbidden,
                message: "Forbidden\n",
                head: head,
                context: context
            )
            return
        }

        if tokenPath {
            guard constantTimeEquals(segments[1], store.token) else {
                failUploadPreparation(
                    status: .notFound,
                    message: "Not Found\n",
                    head: head,
                    context: context
                )
                return
            }
        } else {
            guard cookieAuthorized(head) else {
                failUploadPreparation(
                    status: .unauthorized,
                    message: "Unauthorized\n",
                    head: head,
                    context: context
                )
                return
            }
        }

        let uploadIDValue = queryValue(named: "uploadId", in: head.uri)
        let isStartingNewUpload = uploadIDValue.map { uploadStore.resumable(id: $0) == nil } ?? true
        if isStartingNewUpload {
            guard rateLimiter.allow(
                key: "upload:\(remoteIP)",
                limit: MacdroLimits.uploadStartRateLimitPerMinute,
                interval: 60
            ) else {
                failUploadPreparation(
                    status: .tooManyRequests,
                    message: "Too many uploads. Try again shortly.\n",
                    head: head,
                    context: context
                )
                return
            }
        }

        guard let name = queryValue(named: "name", in: head.uri), !name.isEmpty else {
            failUploadPreparation(
                status: .badRequest,
                message: "Missing file name.\n",
                head: head,
                context: context
            )
            return
        }

        let relativePath = queryValue(named: "path", in: head.uri)
        let client = remoteIP

        if let id = uploadIDValue {
            prepareResumableUpload(
                id: id,
                name: name,
                relativePath: relativePath,
                client: client,
                head: head,
                context: context
            )
            return
        }

        let expectedSize = head.headers.first(name: "Content-Length").flatMap(UInt64.init)
        do {
            upload = try uploadStore.begin(
                name: name,
                relativePath: relativePath,
                expectedSize: expectedSize,
                client: client
            )
            sendContinueIfNeeded(head: head, context: context)
        } catch {
            logger.error("Could not start upload: \(error)")
            failUploadPreparation(
                failure: uploadFailure(for: error),
                head: head,
                context: context
            )
        }
    }

    private func prepareResumableUpload(
        id: String,
        name: String,
        relativePath: String?,
        client: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard Self.isValidUploadID(id) else {
            failUploadPreparation(
                status: .badRequest,
                message: "Invalid upload ID.\n",
                head: head,
                context: context
            )
            return
        }

        let offset: UInt64
        if let rawOffset = queryValue(named: "offset", in: head.uri) {
            guard let parsed = UInt64(rawOffset) else {
                failUploadPreparation(
                    status: .badRequest,
                    message: "Invalid upload offset.\n",
                    head: head,
                    context: context
                )
                return
            }
            offset = parsed
        } else {
            offset = 0
        }

        let total: UInt64?
        if let rawTotal = queryValue(named: "total", in: head.uri) {
            guard let parsed = UInt64(rawTotal) else {
                failUploadPreparation(
                    status: .badRequest,
                    message: "Invalid upload size.\n",
                    head: head,
                    context: context
                )
                return
            }
            total = parsed
        } else {
            total = nil
        }

        let complete = queryValue(named: "complete", in: head.uri).map {
            $0 == "1" || $0.lowercased() == "true"
        } ?? false

        do {
            upload = try uploadStore.beginResumable(
                id: id,
                name: name,
                relativePath: relativePath,
                expectedSize: total,
                offset: offset,
                complete: complete,
                client: client
            )
            uploadID = id
            resumable = true
            completeUpload = complete
            resumableLeaseID = id
            sendContinueIfNeeded(head: head, context: context)
        } catch {
            logger.error("Could not start resumable upload: \(error)")
            uploadID = nil
            resumable = false
            completeUpload = false
            failUploadPreparation(
                failure: uploadFailure(for: error),
                head: head,
                context: context
            )
        }
    }

    private func failUploadPreparation(
        status: HTTPResponseStatus,
        message: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        failUploadPreparation(
            failure: UploadFailure(status: status, message: message),
            head: head,
            context: context
        )
    }

    private func failUploadPreparation(
        failure: UploadFailure,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        uploadFailure = failure
        respondEarlyFailure(failure, head: head, context: context)
    }

    private func respondEarlyFailure(
        _ failure: UploadFailure,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        var headers = failure.headers
        headers.append(("Connection", "close"))
        isRejectingRequest = true
        uploadFailure = nil
        respond(
            context: context,
            request: head,
            status: failure.status,
            contentType: "text/plain; charset=utf-8",
            body: Data(failure.message.utf8),
            extraHeaders: headers,
            onComplete: expectsContinue(head) ? { context.close(promise: nil) } : nil
        )
    }

    private func uploadFailure(for error: Error) -> UploadFailure {
        guard let uploadError = error as? UploadError else {
            return UploadFailure(
                status: .internalServerError,
                message: "Could not save the uploaded file.\n"
            )
        }
        switch uploadError {
        case .insufficientStorage, .capacityUnavailable:
            return UploadFailure(
                status: .insufficientStorage,
                message: "Not enough free disk space to save the upload.\n"
            )
        case .tooManyUploads:
            return UploadFailure(
                status: .tooManyRequests,
                message: "Too many active uploads. Try again later.\n"
            )
        case .uploadLimitExceeded:
            return UploadFailure(
                status: .payloadTooLarge,
                message: "The file exceeds the upload size limit.\n"
            )
        case .uploadInProgress(let offset):
            return UploadFailure(
                status: .conflict,
                message: "This upload is already being written.\n",
                headers: [("X-Upload-Offset", "\(offset)")]
            )
        case .offsetMismatch(let expected):
            return UploadFailure(
                status: .conflict,
                message: "Upload offset mismatch.\n",
                headers: [("X-Upload-Offset", "\(expected)")]
            )
        case .uploadCompleted(let offset):
            return UploadFailure(
                status: .conflict,
                message: "This upload has already completed.\n",
                headers: [("X-Upload-Offset", "\(offset)")]
            )
        case .fileNameTooLong:
            return UploadFailure(
                status: .badRequest,
                message: "The requested file name or path is too long.\n"
            )
        case .fileCreationFailed, .alreadyFinished, .sizeMismatch:
            return UploadFailure(
                status: .badRequest,
                message: "Could not save the uploaded file.\n"
            )
        case .unsafePath:
            return UploadFailure(
                status: .badRequest,
                message: "The requested upload path is not allowed.\n"
            )
        }
    }

    private static func isValidUploadID(_ id: String) -> Bool {
        guard (8...80).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                byte == 45 ||
                byte == 95
        }
    }

    private func sendContinueIfNeeded(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.headers.first(name: "Expect")?.lowercased() == "100-continue" else {
            return
        }
        let response = HTTPResponseHead(version: head.version, status: .`continue`)
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        context.flush()
    }

    private func respondUpload(
        _ result: UploadResult,
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        onComplete: (() -> Void)? = nil
    ) {
        struct UploadResponse: Encodable {
            let name: String
            let path: String
            let size: UInt64
            let offset: UInt64
            let complete: Bool
            let checksum: String
        }

        do {
            let payload = UploadResponse(
                name: result.name,
                path: result.relativePath,
                size: result.size,
                offset: result.size,
                complete: true,
                checksum: result.checksum
            )
            let body = try JSONEncoder().encode(payload)
            respond(
                context: context,
                request: request,
                status: .created,
                contentType: "application/json; charset=utf-8",
                body: body,
                extraHeaders: [
                    ("X-Upload-Offset", "\(result.size)"),
                    ("X-Checksum-SHA256", result.checksum)
                ],
                onComplete: onComplete
            )
        } catch {
            logger.error("Could not encode upload response: \(error)")
            respond(
                context: context,
                request: request,
                status: .internalServerError,
                contentType: "text/plain; charset=utf-8",
                body: Data("Could not encode the upload response.\n".utf8),
                onComplete: onComplete
            )
        }
    }

    private func respondUploadChunk(
        _ upload: UploadTransaction,
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        onComplete: (() -> Void)? = nil
    ) {
        struct ChunkResponse: Encodable {
            let name: String
            let path: String
            let size: UInt64
            let offset: UInt64
            let complete: Bool
        }

        let size = upload.bytesWritten
        do {
            let body = try JSONEncoder().encode(
                ChunkResponse(
                    name: upload.name,
                    path: upload.relativePath,
                    size: size,
                    offset: size,
                    complete: false
                )
            )
            respond(
                context: context,
                request: request,
                status: .ok,
                contentType: "application/json; charset=utf-8",
                body: body,
                extraHeaders: [("X-Upload-Offset", "\(size)")],
                onComplete: onComplete
            )
        } catch {
            logger.error("Could not encode upload response: \(error)")
            respond(
                context: context,
                request: request,
                status: .internalServerError,
                contentType: "text/plain; charset=utf-8",
                body: Data("Could not encode the upload response.\n".utf8),
                onComplete: onComplete
            )
        }
    }

    private func queryValue(named name: String, in uri: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(uri)") else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func serveSessionJSON(context: ChannelHandlerContext, request: HTTPRequestHead) {
        do {
            let data = try sessionData()
            respond(
                context: context,
                request: request,
                status: .ok,
                contentType: "application/json; charset=utf-8",
                body: data
            )
        } catch {
            respond(
                context: context,
                request: request,
                status: .internalServerError,
                contentType: "text/plain; charset=utf-8",
                body: Data("Could not encode session\n".utf8)
            )
        }
    }

    private func sessionData() throws -> Data {
        let snapshot = store.snapshot()
        let payload = SessionPayload(
            totalBytes: snapshot.totalBytes,
            files: snapshot.files.map {
                SessionFilePayload(
                    id: $0.id.uuidString.lowercased(),
                    name: $0.name,
                    path: $0.relativePath,
                    size: $0.size,
                    contentType: $0.contentType,
                    url: "/f/\($0.id.uuidString.lowercased())"
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private func sessionSignature(_ snapshot: SessionSnapshot) -> String {
        snapshot.files.map { "\($0.id.uuidString.lowercased()):\($0.size)" }.joined(separator: "|")
    }

    private func startEventStream(context: ChannelHandlerContext, request: HTTPRequestHead) {
        guard sseTask == nil else { return }
        isStreamingResponse = true
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Accel-Buffering", value: "no")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        let response = HTTPResponseHead(version: request.version, status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        context.flush()

        let initial = store.snapshot()
        sseLastSignature = sessionSignature(initial)
        sseAuthGeneration = store.authGeneration
        sseStartedAt = Date()
        sseLastWrite = Date()
        writeEvent(sessionData: try? sessionData(), context: context)

        sseTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(2),
            delay: .seconds(2)
        ) { [weak self, weak context] _ in
            guard let self, let context, context.channel.isActive else {
                self?.sseTask?.cancel()
                self?.sseTask = nil
                return
            }
            guard self.store.authGeneration == self.sseAuthGeneration else {
                self.sseTask?.cancel()
                self.sseTask = nil
                context.close(promise: nil)
                return
            }
            guard Date().timeIntervalSince(self.sseStartedAt) < MacdroLimits.sseMaxLifetimeSeconds else {
                self.sseTask?.cancel()
                self.sseTask = nil
                context.close(promise: nil)
                return
            }

            let snapshot = self.store.snapshot()
            let signature = self.sessionSignature(snapshot)
            if signature != self.sseLastSignature {
                self.sseLastSignature = signature
                self.writeEvent(sessionData: try? self.sessionData(), context: context)
            } else if Date().timeIntervalSince(self.sseLastWrite) >= MacdroLimits.sseHeartbeatSeconds {
                var buffer = context.channel.allocator.buffer(capacity: 16)
                buffer.writeString(": keep-alive\n\n")
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                self.sseLastWrite = Date()
            }
        }
    }

    private func writeEvent(sessionData: Data?, context: ChannelHandlerContext) {
        guard let sessionData else { return }
        var buffer = context.channel.allocator.buffer(capacity: sessionData.count + 8)
        buffer.writeString("data: ")
        buffer.writeBytes(sessionData)
        buffer.writeString("\n\n")
        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        sseLastWrite = Date()
    }

    private func handleClipboard(
        head: HTTPRequestHead,
        body: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        switch head.method {
        case .GET, .HEAD:
            readClipboard(context: context, request: head)
        case .PUT, .POST:
            guard body.readableBytes <= MacdroLimits.maxClipboardBytes,
                  let text = body.getString(at: body.readerIndex, length: body.readableBytes)
            else {
                respond(
                    context: context,
                    request: head,
                    status: .payloadTooLarge,
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Clipboard text is too large.\n".utf8)
                )
                return
            }
            writeClipboard(text, context: context, request: head)
        default:
            var headers = HTTPHeaders()
            headers.add(name: "Allow", value: "GET, HEAD, PUT, POST")
            respond(
                context: context,
                request: head,
                status: .methodNotAllowed,
                contentType: "text/plain; charset=utf-8",
                body: Data("Method not allowed\n".utf8),
                extraHeaders: headers.map { ($0.name, $0.value) }
            )
        }
    }

    private func readClipboard(context: ChannelHandlerContext, request: HTTPRequestHead) {
        let promise = context.eventLoop.makePromise(of: String.self)
        let once = OneShot()
        DispatchQueue.main.async {
            guard once.claim() else { return }
            promise.succeed(NSPasteboard.general.string(forType: .string) ?? "")
        }
        let timeout = context.eventLoop.scheduleTask(in: .seconds(2)) {
            guard once.claim() else { return }
            promise.fail(ClipboardBridgeError.timeout)
        }
        promise.futureResult.whenComplete { [weak self] result in
            timeout.cancel()
            guard let self else { return }
            switch result {
            case .success(let text):
                let data = Data(text.utf8)
                guard data.count <= MacdroLimits.maxClipboardBytes else {
                    self.respond(
                        context: context,
                        request: request,
                        status: .payloadTooLarge,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Clipboard text is too large.\n".utf8)
                    )
                    return
                }
                self.respond(
                    context: context,
                    request: request,
                    status: .ok,
                    contentType: "text/plain; charset=utf-8",
                    body: data
                )
            case .failure:
                self.respond(
                    context: context,
                    request: request,
                    status: .serviceUnavailable,
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Could not read the Mac clipboard.\n".utf8)
                )
            }
        }
    }

    private func writeClipboard(
        _ text: String,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        let once = OneShot()
        DispatchQueue.main.async {
            guard once.claim() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            promise.succeed(())
        }
        let timeout = context.eventLoop.scheduleTask(in: .seconds(2)) {
            guard once.claim() else { return }
            promise.fail(ClipboardBridgeError.timeout)
        }
        promise.futureResult.whenComplete { [weak self] result in
            timeout.cancel()
            guard let self else { return }
            switch result {
            case .success:
                self.respond(
                    context: context,
                    request: request,
                    status: .noContent,
                    contentType: "text/plain; charset=utf-8",
                    body: Data()
                )
            case .failure:
                self.respond(
                    context: context,
                    request: request,
                    status: .serviceUnavailable,
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Could not update the Mac clipboard.\n".utf8)
                )
            }
        }
    }

    private func serveManifest(context: ChannelHandlerContext, request: HTTPRequestHead) {
        isStreamingResponse = true
        let snapshot = store.snapshot()
        guard !snapshot.files.isEmpty else {
            respond(
                context: context,
                request: request,
                status: .ok,
                contentType: "application/json; charset=utf-8",
                body: Data("{\"files\":[]}".utf8)
            )
            return
        }

        manifestService.data(for: snapshot) { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                switch result {
                case .success(let body):
                    self.respond(
                        context: context,
                        request: request,
                        status: .ok,
                        contentType: "application/json; charset=utf-8",
                        body: body
                    )
                case .failure(let error):
                    self.logger.error("Could not compute manifest: \(error)")
                    self.respond(
                        context: context,
                        request: request,
                        status: .internalServerError,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Could not compute manifest\n".utf8)
                    )
                }
            }
        }
    }

    private func serveArchive(context: ChannelHandlerContext, request: HTTPRequestHead) {
        isStreamingResponse = true
        let snapshot = store.snapshot()
        guard !snapshot.files.isEmpty else {
            notFound(context: context, request: request)
            return
        }

        archiveService.archive(for: snapshot) { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.serveTemporaryArchive(url, context: context, request: request)
                case .failure(let error):
                    self.logger.error("Could not build ZIP archive: \(error)")
                    let status: HTTPResponseStatus
                    if let archiveError = error as? ArchiveServiceError {
                        switch archiveError {
                        case .tooManyEntries, .archiveTooLarge:
                            status = .payloadTooLarge
                        case .noFiles:
                            status = .notFound
                        case .unavailable:
                            status = .serviceUnavailable
                        }
                    } else {
                        status = .internalServerError
                    }
                    self.respond(
                        context: context,
                        request: request,
                        status: status,
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Could not build the archive.\n".utf8)
                    )
                }
            }
        }
    }

    private func serveTemporaryArchive(
        _ archiveURL: URL,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        isStreamingResponse = true
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: archiveURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            notFound(context: context, request: request)
            return
        }

        let handle: NIOFileHandle
        do {
            handle = try openFileHandle(at: archiveURL.path)
        } catch {
            respond(
                context: context,
                request: request,
                status: .internalServerError,
                contentType: "text/plain; charset=utf-8",
                body: Data("Could not open the archive.\n".utf8)
            )
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/zip")
        headers.add(name: "Content-Length", value: "\(size)")
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"Macdro.zip\"")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        if !request.isKeepAlive {
            headers.add(name: "Connection", value: "close")
        }
        let response = HTTPResponseHead(version: request.version, status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        sendFileBody(
            handle: handle,
            start: 0,
            length: size,
            context: context,
            request: request
        )
    }

    private func openFileHandle(at path: String) throws -> NIOFileHandle {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: descriptor)
    }

    private static func safeArchivePath(_ path: String) -> String {
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        return components.isEmpty ? "file" : components.joined(separator: "/")
    }

    private func serveWebAsset(
        _ name: String,
        contentType: String,
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        extraHeaders: [(String, String)] = []
    ) {
        guard (request.method == .GET || request.method == .HEAD) else {
            methodNotAllowed(context: context, request: request)
            return
        }

        let fileURL = webRoot.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileURL) else {
            respond(
                context: context,
                request: request,
                status: .internalServerError,
                contentType: "text/plain; charset=utf-8",
                body: Data("Receiver UI is unavailable\n".utf8)
            )
            return
        }

        respond(
            context: context,
            request: request,
            status: .ok,
            contentType: contentType,
            body: data,
            cacheControl: "no-store",
            extraHeaders: extraHeaders
        )
    }

    private func serveFile(
        _ file: SharedFile,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        guard request.method == .GET || request.method == .HEAD else {
            methodNotAllowed(context: context, request: request)
            return
        }

        isStreamingResponse = true
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.sourcePath, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            notFound(context: context, request: request)
            return
        }

        let attributes = try? fileManager.attributesOfItem(atPath: file.sourcePath)
        let identity = try? FileMetadata.identity(for: file.sourceURL)
        let size = identity?.size ?? (attributes?[.size] as? NSNumber)?.uint64Value ?? file.size
        let modified = (attributes?[.modificationDate] as? Date) ?? file.modifiedAt
        let etag = (try? FileMetadata.etag(for: file.sourceURL))
            ?? "\"\(size)-\(DateEpoch.seconds(modified))\""

        if request.headers.first(name: "If-None-Match") == etag,
           request.headers.first(name: "Range") == nil
        {
            var headers = HTTPHeaders()
            headers.add(name: "ETag", value: etag)
            headers.add(name: "Cache-Control", value: "no-store")
            if !request.isKeepAlive {
                headers.add(name: "Connection", value: "close")
            }
            let response = HTTPResponseHead(version: request.version, status: .notModified, headers: headers)
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            let future = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
            if !request.isKeepAlive {
                future.whenComplete { _ in context.close(promise: nil) }
            }
            return
        }

        var rangeHeader = request.headers.first(name: "Range")
        if let ifRange = request.headers.first(name: "If-Range"),
           ifRange != etag
        {
            rangeHeader = nil
        }

        let rangeResult = RangeRequest.parse(header: rangeHeader, fileSize: size)
        var start: UInt64 = 0
        var end: UInt64 = size > 0 ? size - 1 : 0
        var status: HTTPResponseStatus = .ok

        switch rangeResult {
        case .full:
            status = .ok
        case .partial(let range):
            start = range.start
            end = range.end
            status = .partialContent
        case .unsatisfiable:
            var headers = HTTPHeaders()
            headers.add(name: "Content-Range", value: "bytes */\(size)")
            headers.add(name: "Content-Length", value: "0")
            headers.add(name: "Accept-Ranges", value: "bytes")
            headers.add(name: "ETag", value: etag)
            if !request.isKeepAlive {
                headers.add(name: "Connection", value: "close")
            }
            let response = HTTPResponseHead(version: request.version, status: .rangeNotSatisfiable, headers: headers)
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            let future = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
            if !request.isKeepAlive {
                future.whenComplete { _ in context.close(promise: nil) }
            }
            return
        }

        let length: UInt64 = size == 0 ? 0 : (end >= start ? end - start + 1 : 0)
        let handle: NIOFileHandle
        do {
            handle = try openFileHandle(at: file.sourcePath)
        } catch {
            logger.error("Could not open shared file: \(error)")
            respond(
                context: context,
                request: request,
                status: .internalServerError,
                contentType: "text/plain; charset=utf-8",
                body: Data("Could not open file\n".utf8)
            )
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: file.contentType)
        headers.add(name: "Content-Length", value: "\(length)")
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "ETag", value: etag)
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        addSecurityHeaders(to: &headers, contentType: file.contentType)
        headers.add(name: "Content-Disposition", value: contentDisposition(for: file.name))
        headers.add(name: "Last-Modified", value: httpDate(modified))
        if status == .partialContent {
            headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(size)")
        }
        if !request.isKeepAlive {
            headers.add(name: "Connection", value: "close")
        }

        let responseHead = HTTPResponseHead(version: request.version, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        sendFileBody(
            handle: handle,
            start: start,
            length: length,
            context: context,
            request: request
        )
    }

    private func sendFileBody(
        handle: NIOFileHandle,
        start: UInt64,
        length: UInt64,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        let keepAlive = request.isKeepAlive
        guard request.method != .HEAD, length > 0 else {
            Self.finishFileResponse(handle: handle, context: context, keepAlive: keepAlive)
            return
        }

        let region = FileRegion(
            fileHandle: handle,
            readerIndex: Int(start),
            endIndex: Int(start + length)
        )

        if !isSecure {
            context.write(self.wrapOutboundOut(.body(.fileRegion(region))), promise: nil)
            Self.finishFileResponse(handle: handle, context: context, keepAlive: keepAlive)
            return
        }

        let logger = self.logger
        let fileIO = NonBlockingFileIO(threadPool: ioPool)
        fileIO.readChunked(
            fileRegion: region,
            chunkSize: 256 * 1024,
            allocator: context.channel.allocator,
            eventLoop: context.eventLoop
        ) { buffer in
            context.writeAndFlush(
                NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer)))
            )
        }.whenComplete { result in
            switch result {
            case .success:
                Self.finishFileResponse(
                    handle: handle,
                    context: context,
                    keepAlive: keepAlive
                )
            case .failure(let error):
                logger.error("Could not stream file body: \(error)")
                try? handle.close()
                context.close(promise: nil)
            }
        }
    }

    private static func finishFileResponse(
        handle: NIOFileHandle,
        context: ChannelHandlerContext,
        keepAlive: Bool
    ) {
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            try? handle.close()
            if !keepAlive {
                context.close(promise: nil)
            }
        }
    }

    private func respond(
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        status: HTTPResponseStatus,
        contentType: String,
        body: Data,
        cacheControl: String = "no-store",
        extraHeaders: [(String, String)] = [],
        onComplete: (() -> Void)? = nil
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Cache-Control", value: cacheControl)
        addSecurityHeaders(to: &headers, contentType: contentType)
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        if !request.isKeepAlive {
            headers.add(name: "Connection", value: "close")
        }

        let responseHead = HTTPResponseHead(version: request.version, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        if request.method != .HEAD, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        let future = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
        if !request.isKeepAlive {
            future.whenComplete { _ in
                onComplete?()
                context.close(promise: nil)
            }
        } else {
            future.whenComplete { _ in onComplete?() }
        }
    }

    private func redirect(context: ChannelHandlerContext, request: HTTPRequestHead, to location: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: location)
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Cache-Control", value: "no-store")
        if !request.isKeepAlive {
            headers.add(name: "Connection", value: "close")
        }
        let response = HTTPResponseHead(version: request.version, status: .found, headers: headers)
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        let future = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
        if !request.isKeepAlive {
            future.whenComplete { _ in context.close(promise: nil) }
        }
    }

    private func allowRateLimit(
        scope: String,
        limit: Int,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) -> Bool {
        guard rateLimiter.allow(key: "\(scope):\(clientID)", limit: limit, interval: 60) else {
            respond(
                context: context,
                request: head,
                status: .tooManyRequests,
                contentType: "text/plain; charset=utf-8",
                body: Data("Too many requests. Try again shortly.\n".utf8),
                extraHeaders: [("Retry-After", "30")]
            )
            return false
        }
        return true
    }

    private func serveLanding(context: ChannelHandlerContext, request: HTTPRequestHead) {
        guard request.method == .GET || request.method == .HEAD else {
            methodNotAllowed(context: context, request: request)
            return
        }
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Macdro</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1.25rem;line-height:1.55}
        p{opacity:.72}
        </style>
        </head>
        <body>
        <h1>Macdro</h1>
        <p>This Mac is running Macdro. Open the full receiver link from the QR code shown in Macdro on your Mac. The link contains a private session token and should not be shared.</p>
        </body>
        </html>
        """
        respond(
            context: context,
            request: request,
            status: .ok,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8)
        )
    }

    private func notFound(context: ChannelHandlerContext, request: HTTPRequestHead) {
        respond(
            context: context,
            request: request,
            status: .notFound,
            contentType: "text/plain; charset=utf-8",
            body: Data("Not found\n".utf8)
        )
    }

    private func methodNotAllowed(context: ChannelHandlerContext, request: HTTPRequestHead) {
        var headers = HTTPHeaders()
        headers.add(name: "Allow", value: "GET, HEAD")
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "19")
        if !request.isKeepAlive {
            headers.add(name: "Connection", value: "close")
        }
        let response = HTTPResponseHead(version: request.version, status: .methodNotAllowed, headers: headers)
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        if request.method != .HEAD {
            var buffer = context.channel.allocator.buffer(capacity: 19)
            buffer.writeString("Method not allowed\n")
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let future = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
        if !request.isKeepAlive {
            future.whenComplete { _ in context.close(promise: nil) }
        }
    }

    private func pathComponent(of uri: String) -> String {
        guard let question = uri.firstIndex(of: "?") else { return uri }
        return String(uri[..<question])
    }

    private func contentDisposition(for filename: String) -> String {
        let safe = sanitizedHeaderName(filename)
        let fallbackScalars = safe.unicodeScalars.map { scalar -> Character in
            let isPrintableASCII = scalar.isASCII && scalar.value >= 0x20 && scalar.value <= 0x7E
            let isUnsafe = scalar == "\"" || scalar == "\\" || scalar == ":"
            return isPrintableASCII && !isUnsafe ? Character(scalar) : "_"
        }
        let fallback = String(fallbackScalars).isEmpty ? "file" : String(fallbackScalars)
        let encoded = percentEncodeRFC5987(safe)
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    private func sanitizedHeaderName(_ value: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{FEFF}"
        ]
        var result = ""
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || dangerous.contains(scalar) {
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? "file" : result
    }

    private func percentEncodeRFC5987(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
    }

    private func rejectOversizedBody(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard !isRejectingRequest else { return }
        isRejectingRequest = true
        requestBody.clear()
        upload = nil
        uploadFailure = nil
        uploadID = nil
        resumable = false
        completeUpload = false

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "no-store")
        let response = HTTPResponseHead(
            version: head.version,
            status: .payloadTooLarge,
            headers: headers
        )
        rejectedBodyBytes = 0
        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
        let future = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
        if expectsContinue(head) {
            future.whenComplete { _ in context.close(promise: nil) }
        }
    }

    private func expectsContinue(_ head: HTTPRequestHead) -> Bool {
        head.headers.first(name: "Expect")?.lowercased().contains("100-continue") == true
    }

    private func uploadErrorStatus(_ error: Error) -> HTTPResponseStatus {
        guard let uploadError = error as? UploadError else {
            return .internalServerError
        }
        switch uploadError {
        case .insufficientStorage, .capacityUnavailable:
            return .insufficientStorage
        case .tooManyUploads:
            return .tooManyRequests
        case .uploadLimitExceeded:
            return .payloadTooLarge
        case .uploadInProgress, .offsetMismatch, .uploadCompleted:
            return .conflict
        case .fileCreationFailed, .alreadyFinished, .sizeMismatch, .fileNameTooLong, .unsafePath:
            return .badRequest
        }
    }

    private func uploadErrorMessage(_ error: Error) -> String {
        guard let uploadError = error as? UploadError else {
            return "Could not save the uploaded file.\n"
        }
        return String(describing: uploadError.errorDescription ?? "Could not save the uploaded file.") + "\n"
    }

    private func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private var sessionCookieHeader: String {
        let secure = isSecure ? "; Secure" : ""
        return "\(SessionStore.cookieName)=\(store.sessionCookie); Path=/; HttpOnly; SameSite=Strict\(secure)"
    }

    private func cookieAuthorized(_ head: HTTPRequestHead) -> Bool {
        guard let cookieHeader = head.headers.first(name: "Cookie") else { return false }
        let expected = store.sessionCookie
        for pair in cookieHeader.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<equals])
            guard name == SessionStore.cookieName else { continue }
            let value = String(trimmed[trimmed.index(after: equals)...])
            return constantTimeEquals(value, expected)
        }
        return false
    }

    private func unauthorized(context: ChannelHandlerContext, request: HTTPRequestHead) {
        respond(
            context: context,
            request: request,
            status: .unauthorized,
            contentType: "text/plain; charset=utf-8",
            body: Data("Unauthorized\n".utf8)
        )
    }

    private func addSecurityHeaders(to headers: inout HTTPHeaders, contentType: String) {
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "X-Frame-Options", value: "DENY")
        headers.add(name: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        if contentType.hasPrefix("text/html") || contentType.hasPrefix("text/javascript") {
            headers.add(
                name: "Content-Security-Policy",
                value: "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
                    + "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; "
                    + "base-uri 'none'; form-action 'self'"
            )
        }
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

private enum ClipboardBridgeError: Error {
    case timeout
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

private struct SessionPayload: Encodable {
    let totalBytes: UInt64
    let files: [SessionFilePayload]
}

private struct SessionFilePayload: Encodable {
    let id: String
    let name: String
    let path: String
    let size: UInt64
    let contentType: String
    let url: String
}
