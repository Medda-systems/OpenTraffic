import CryptoKit
import Foundation
import Security
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import os

/// The collaboration proxy for one share. It sits between the tunnel connector and the local
/// server on 127.0.0.1 and forwards everything unchanged, except that HTML pages get the overlay
/// script and `/__opentraffic/*` is answered here (overlay script, host link, WebSocket hub).
/// Other WebSocket upgrades (hot reload) are relayed byte for byte.
///
/// All connection state lives on one event loop; see specs/collab-plan.md.
public final class CollabProxy: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var upstreamHost: String
        public var upstreamPort: Int
        public var overlayScript: Data
        /// The host's name in the session ("Host" when empty).
        public var hostName: String?
        /// The localhost bridge (`bridge.js`), served after its generated configuration line.
        public var bridgeScript: Data
        /// Where uploaded screenshots are kept; nil turns uploads off.
        public var attachmentsDirectory: URL?
        /// Add the collaboration overlay to pages. Off, the proxy only forwards (for the Host header fix).
        public var injectsOverlay: Bool
        /// Send every request to the local server with its own address as the Host header, for dev
        /// servers that reject the public hostname.
        public var rewritesHostHeader: Bool
        /// Cap hub connections per visitor address. Only meaningful when the tunnel says who the
        /// visitor is (Cloudflare's CF-Connecting-IP); otherwise everyone looks like 127.0.0.1.
        public var limitsConnectionsPerAddress: Bool
        /// The Electron host serving this share's app (electron-host.js): `/__opentraffic/electron/*`
        /// goes there, and pages get its preload script first thing in <head>.
        public var electronHostPort: Int?

        public init(
            upstreamHost: String,
            upstreamPort: Int,
            overlayScript: Data,
            hostName: String? = nil,
            bridgeScript: Data = Data(),
            attachmentsDirectory: URL? = nil,
            injectsOverlay: Bool = true,
            rewritesHostHeader: Bool = false,
            limitsConnectionsPerAddress: Bool = true,
            electronHostPort: Int? = nil
        ) {
            self.upstreamHost = upstreamHost
            self.upstreamPort = upstreamPort
            self.overlayScript = overlayScript
            self.hostName = hostName
            self.bridgeScript = bridgeScript
            self.attachmentsDirectory = attachmentsDirectory
            self.injectsOverlay = injectsOverlay
            self.rewritesHostHeader = rewritesHostHeader
            self.limitsConnectionsPerAddress = limitsConnectionsPerAddress
            self.electronHostPort = electronHostPort
        }

        /// Where requests from the host's own browser say they're going, as the local server expects.
        var upstreamAuthority: String {
            let host = upstreamHost.contains(":") ? "[\(upstreamHost)]" : upstreamHost
            return "\(host):\(upstreamPort)"
        }
    }

    public static let scriptPath = "/__opentraffic/collab.js"
    public static let socketPath = "/__opentraffic/ws"
    public static let hostPath = "/__opentraffic/host"
    public static let scriptTag = #"<script src="/__opentraffic/collab.js" defer data-opentraffic></script>"#
    public static let bridgePath = "/__opentraffic/bridge.js"
    static let bridgeWantPath = "/__opentraffic/bridge/want"
    static let bridgedPrefix = "/__opentraffic/port/"
    static let electronPrefix = "/__opentraffic/electron/"
    public static let electronPreloadPath = "/__opentraffic/electron/preload.js"
    static let uploadPath = "/__opentraffic/upload"
    static let attachmentsPrefix = "/__opentraffic/attachments/"
    static let maximumUploadBytes = 600 * 1024
    static let maximumAttachmentBytes = 50 * 1024 * 1024
    static let uploadsPerMinute = 10

    static func overlayTag(nonce: String?) -> String {
        nonce.map { #"<script src="/__opentraffic/collab.js" defer data-opentraffic nonce="\#($0)"></script>"# } ?? scriptTag
    }

    static func bridgeTag(nonce: String?) -> String {
        let nonceAttribute = nonce.map { #" nonce="\#($0)""# } ?? ""
        return #"<script src="/__opentraffic/bridge.js" data-opentraffic\#(nonceAttribute)></script>"#
    }

    /// The Electron app's preload (with Electron's renderer modules), right after the bridge.
    static func electronTag(nonce: String?) -> String {
        let nonceAttribute = nonce.map { #" nonce="\#($0)""# } ?? ""
        return #"<script src="/__opentraffic/electron/preload.js" data-opentraffic\#(nonceAttribute)></script>"#
    }
    /// Every share's host cookie starts with this; the port keeps two shares' cookies apart
    /// (browsers don't separate cookies by port).
    static let hostCookiePrefix = "__opentraffic_host"
    /// Hub connections allowed from one visitor address (tabs, reloads in flight).
    static let socketsPerAddress = 20
    /// A hub connection that hasn't said hello by then is closed.
    static let helloTimeout: TimeAmount = .seconds(5)

    /// One small thread serves every share's proxy; development traffic is light.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public let configuration: Configuration
    public let hostToken: String
    let loop: EventLoop

    private struct Shared {
        var port: Int?
        var publicHost: String?
        var peersHandler: (@Sendable ([CollabPeer]) -> Void)?
        var commentsHandler: (@Sendable ([CollabComment]) -> Void)?
        var errorsHandler: (@Sendable ([CollabErrorItem]) -> Void)?
        var bridgeCandidatesHandler: (@Sendable (Int) -> Void)?
        var bridgedPorts: Set<Int> = []
        var reportedCandidates: Set<Int> = []
        /// OpenTraffic's own ports (its API, other shares' proxies): never bridged.
        var reservedPorts: Set<Int> = []
        /// The share's password, when it has one.
        var access: ShareAccess?
        var signInLimiter = SignInLimiter()
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    // Event-loop confined.
    private var serverChannel: Channel?
    private var room: CollabRoom
    private var sockets: [String: Channel] = [:]
    /// Every client connection (page loads, hot-reload relays, hub sockets), closed on stop.
    private var connections: [ObjectIdentifier: Channel] = [:]
    /// The visitor address of each hub connection.
    private var socketAddresses: [String: String] = [:]
    private var lastReportedPeers: [CollabPeer] = []
    private var lastReportedComments: [CollabComment]
    private var uploadTimes: [String: [Date]] = [:]
    private var attachmentBytes = 0

    /// `comments` are restored from an earlier session of the same share.
    public init(configuration: Configuration, comments: [CollabComment] = []) {
        self.configuration = configuration
        self.hostToken = UUID().uuidString + UUID().uuidString
        self.loop = Self.group.next()
        self.room = CollabRoom(hostName: configuration.hostName, comments: comments)
        self.lastReportedComments = comments
        if let directory = configuration.attachmentsDirectory,
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            // Pictures no saved comment uses (uploaded for a comment never posted, or left over).
            let used = Set(comments.flatMap(\.attachments))
            for file in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if used.contains(file.deletingPathExtension().lastPathComponent) || (try? FileManager.default.removeItem(at: file)) == nil {
                    attachmentBytes += size
                }
            }
        }
    }

    /// The port it listens on, once started.
    public var port: Int? { shared.withLock { $0.port } }

    /// The address the tunnel connector should forward to.
    public var localURL: String? { port.map { "http://127.0.0.1:\($0)" } }

    /// Opens the share as the host: sets the host cookie on the local origin, then shows the site.
    public var hostJoinURL: URL? {
        port.flatMap { URL(string: "http://127.0.0.1:\($0)\(Self.hostPath)?token=\(hostToken)") }
    }

    var hostCookie: String { "\(Self.hostCookiePrefix)_\(port ?? 0)" }

    /// Ports a page may never reach through the bridge, whatever it asks for.
    public func setReservedPorts(_ ports: Set<Int>) {
        shared.withLock { $0.reservedPorts = ports }
    }

    /// Puts a password in front of everything the share serves (nil: open). Takes effect for the next
    /// request; a new password signs everyone out, since their cookies were made from the old one.
    public func setAccess(_ access: ShareAccess?) {
        shared.withLock { $0.access = access }
    }

    public var access: ShareAccess? { shared.withLock { $0.access } }

    /// The tunnel's public hostname, so pages served there may open the hub's WebSocket.
    public func setPublicHost(_ host: String?) {
        shared.withLock { $0.publicHost = host?.lowercased() }
    }

    /// Called on the proxy's thread whenever the set of people (or their names/pages) changes.
    public func setPeersHandler(_ handler: @escaping @Sendable ([CollabPeer]) -> Void) {
        shared.withLock { $0.peersHandler = handler }
    }

    /// Called on the proxy's thread whenever comments are added, resolved, or deleted.
    public func setCommentsHandler(_ handler: @escaping @Sendable ([CollabComment]) -> Void) {
        shared.withLock { $0.commentsHandler = handler }
    }

    /// Errors visitors' browsers reported (only while `setCapturesErrors(true)`).
    public func setErrorsHandler(_ handler: @escaping @Sendable ([CollabErrorItem]) -> Void) {
        shared.withLock { $0.errorsHandler = handler }
    }

    /// Loopback ports the shared app tried to reach that aren't bridged yet; each is reported once.
    public func setBridgeCandidatesHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        shared.withLock { $0.bridgeCandidatesHandler = handler }
    }

    /// Local ports reachable through the tunnel at `/__opentraffic/port/<port>/`.
    public func setBridgedPorts(_ ports: Set<Int>) {
        shared.withLock { $0.bridgedPorts = ports.filter { $0 != configuration.upstreamPort && (1...65_535).contains($0) } }
    }

    public var bridgedPorts: Set<Int> { shared.withLock { $0.bridgedPorts } }

    /// Whether visitors' overlays collect browser errors (applies to pages loaded from now on).
    public func setCapturesErrors(_ enabled: Bool) async {
        try? await loop.submit { self.room.capturesErrors = enabled }.get()
    }

    /// Adds a reply from the host or an app; everyone in the session sees it.
    public func addReply(to commentID: String, text: String, author: String, agent: String?) async -> CollabComment? {
        try? await loop.submit { () -> CollabComment? in
            let result = self.room.addReply(to: commentID, text: text, author: author, color: self.room.hostColor, fromHost: true, agent: agent)
            self.deliver(result.messages)
            self.reportCommentsIfChanged()
            return result.comment
        }.get() ?? nil
    }

    /// Resolves or reopens a comment from OpenTraffic; everyone in the session sees the change. `by` is
    /// who resolved it, and `agent` whether that's an app using the API.
    public func resolveComment(_ id: String, resolved: Bool, by name: String? = nil, agent: Bool = false) async {
        try? await loop.submit {
            self.deliver(self.room.resolveComment(id, resolved: resolved, by: name, agent: agent))
            self.reportCommentsIfChanged()
            self.reportPeersIfChanged()
        }.get()
    }

    /// The site changed (the project's files): every page in the session catches up without a reload.
    public func refreshPages() async {
        try? await loop.submit { self.deliver(self.room.refreshMessages()) }.get()
    }

    /// Shows the comments coding agents are working on, and the agents, to everyone in the session.
    /// What people may do: roles by their browser's overlay id, and everyone else's.
    public func setRoles(_ roles: [String: CollabRole], default defaultRole: CollabRole) async {
        try? await loop.submit {
            self.deliver(self.room.setRoles(roles, default: defaultRole))
            self.reportPeersIfChanged()
        }.get()
    }

    public func setAgentWork(_ work: [CollabAgentWork]) async {
        try? await loop.submit {
            self.deliver(self.room.setAgentWork(work))
            self.reportPeersIfChanged()
        }.get()
    }

    /// Deletes a comment from OpenTraffic; it disappears for everyone in the session.
    public func deleteComment(_ id: String) async {
        try? await loop.submit {
            self.deliver(self.room.deleteComment(id))
            self.reportCommentsIfChanged()
            self.reportPeersIfChanged()
        }.get()
    }

    public func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture { try self.configurePipeline(channel) }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0
        try await loop.submit { self.serverChannel = channel }.get()
        shared.withLock { $0.port = port }
        return port
    }

    public func stop() async {
        let channels: [Channel] = (try? await loop.submit { () -> [Channel] in
            let all = Array(self.connections.values) + [self.serverChannel].compactMap { $0 }
            self.serverChannel = nil
            return all
        }.get()) ?? []
        for channel in channels { try? await channel.close() }
    }

    // MARK: Pipeline

    // Upgrades (the hub's WebSocket and hot-reload sockets) are handled by ProxyHandler rather than
    // NIO's upgrade handler, which only considers the first request on a connection — and the tunnel
    // connector reuses connections, so an upgrade often arrives after other requests.
    private func configurePipeline(_ channel: Channel) throws {
        let key = ObjectIdentifier(channel)
        connections[key] = channel
        channel.closeFuture.whenComplete { [weak self] _ in self?.connections[key] = nil }
        let sync = channel.pipeline.syncOperations
        let encoder = HTTPResponseEncoder()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let pipelining = HTTPServerPipelineHandler()
        let errors = HTTPServerProtocolErrorHandler()
        try sync.addHandler(encoder)
        try sync.addHandler(decoder)
        try sync.addHandler(pipelining)
        try sync.addHandler(errors)
        try sync.addHandler(ProxyHandler(proxy: self, encoder: encoder, decoder: decoder, downstream: [pipelining, errors]))
    }

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key` (RFC 6455).
    static func webSocketAccept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    // MARK: Requests from the host's browser

    func isLocalAuthority(_ head: HTTPRequestHead) -> Bool {
        guard let port, let host = head.headers.first(name: "host")?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    func isHost(_ head: HTTPRequestHead) -> Bool {
        isLocalAuthority(head) && Self.cookie(hostCookie, in: head.headers) == hostToken
    }

    // MARK: Password

    enum AccessGate: Equatable {
        /// OpenTraffic's sign-in page (asked for directly, or in place of a page the visitor can't open yet).
        case signInPage(next: String)
        case signIn
        /// A valid invite link: sign in and continue to `next`.
        case invite(next: String)
        /// Anything else without access: 401, with basic auth offered to tools.
        case refused
    }

    /// What to do with a request instead of serving it, or nil to serve it. The host (holding the
    /// host link's cookie) always gets through; the Host header proves nothing, since a tunnel's
    /// visitors can set it.
    func gate(_ head: HTTPRequestHead) -> AccessGate? {
        guard let access else { return nil }
        let path = Self.path(of: head.uri)
        if path == Self.hostPath { return nil }
        if path == ShareAccess.signInPath {
            return head.method == .POST ? .signIn : .signInPage(next: ShareAccess.safeNext(Self.query("next", in: head.uri)))
        }
        if Self.cookie(hostCookie, in: head.headers) == hostToken { return nil }
        if let cookie = Self.cookie(ShareAccess.cookieName, in: head.headers), access.accepts(cookie: cookie) { return nil }
        if let authorization = head.headers.first(name: "authorization"), access.accepts(authorization: authorization) { return nil }
        let reads = head.method == .GET || head.method == .HEAD
        if reads, let invite = Self.query(ShareAccess.inviteParameter, in: head.uri), access.accepts(invite: invite) {
            return .invite(next: ShareAccess.removingInvite(from: head.uri))
        }
        return reads && Self.wantsPage(head) ? .signInPage(next: ShareAccess.safeNext(head.uri)) : .refused
    }

    /// A browser opening a page (rather than a script fetching data).
    static func wantsPage(_ head: HTTPRequestHead) -> Bool {
        if let mode = head.headers.first(name: "sec-fetch-mode")?.lowercased() { return mode == "navigate" }
        return head.headers[canonicalForm: "accept"].contains { $0.lowercased().contains("text/html") }
    }

    /// Checks a submitted password. Wrong tries count against the visitor (or the share, when the
    /// tunnel doesn't say who's visiting).
    func signIn(password: String, from address: String?, now: Date = Date()) -> SignInResult {
        shared.withLock { state in
            guard let access = state.access else { return .wrong }
            let key = address ?? "share"
            guard state.signInLimiter.allows(key, now: now) else { return .limited }
            if access.accepts(password: password) { return .accepted(access) }
            state.signInLimiter.failed(key, at: now)
            return .wrong
        }
    }

    enum SignInResult {
        case accepted(ShareAccess)
        case wrong
        case limited
    }

    /// The hub only accepts pages served by this share (public hostname or the local host link),
    /// so other sites can't open it from a visitor's browser.
    func acceptsSocket(_ head: HTTPRequestHead) -> Bool {
        guard Self.path(of: head.uri) == Self.socketPath else { return false }
        return acceptsOrigin(head)
    }

    /// Whether a request comes from a page this share served (its public hostname or the local host link).
    func acceptsOrigin(_ head: HTTPRequestHead) -> Bool {
        guard let origin = head.headers.first(name: "origin").flatMap(URL.init(string:)),
              let originHost = origin.host?.lowercased() else { return false }
        let authority = origin.port.map { "\(originHost):\($0)" } ?? originHost
        var allowed: Set<String> = []
        if let host = head.headers.first(name: "host")?.lowercased() { allowed.insert(host) }
        let (port, publicHost) = shared.withLock { ($0.port, $0.publicHost) }
        if let publicHost { allowed.insert(publicHost) }
        if let port { allowed.formUnion(["127.0.0.1:\(port)", "localhost:\(port)"]) }
        return allowed.contains(authority)
    }

    // MARK: Hub (event loop)

    /// Whether a new hub connection from `address` is let in.
    private func hasRoom(isHost: Bool, address: String) -> Bool {
        loop.preconditionInEventLoop()
        guard room.hasRoom(isHost: isHost) else { return false }
        guard !isHost, configuration.limitsConnectionsPerAddress else { return true }
        return socketAddresses.values.filter { $0 == address }.count < Self.socketsPerAddress
    }

    func socketConnected(_ channel: Channel, isHost: Bool, address: String) -> String? {
        loop.preconditionInEventLoop()
        guard hasRoom(isHost: isHost, address: address), let id = room.connect(isHost: isHost) else { return nil }
        sockets[id] = channel
        socketAddresses[id] = address
        return id
    }

    func socketIsJoined(_ id: String) -> Bool {
        room.isJoined(id)
    }

    func socketReceived(_ text: String, from id: String) {
        deliver(room.receive(text, from: id))
        reportPeersIfChanged()
        reportCommentsIfChanged()
        let errors = room.takeReportedErrors()
        if !errors.isEmpty { shared.withLock { $0.errorsHandler }?(errors) }
    }

    // MARK: Bridge and uploads (event loop)

    func allowsBridgedPort(_ port: Int) -> Bool {
        port != configuration.electronHostPort &&
            shared.withLock { $0.bridgedPorts.contains(port) && !$0.reservedPorts.contains(port) && port != $0.port }
    }

    func reportBridgeCandidate(_ port: Int) {
        guard (1...65_535).contains(port), port != configuration.upstreamPort else { return }
        let handler = shared.withLock { state -> (@Sendable (Int) -> Void)? in
            guard !state.bridgedPorts.contains(port), !state.reservedPorts.contains(port), port != state.port,
                  state.reportedCandidates.count < 32,
                  state.reportedCandidates.insert(port).inserted else { return nil }
            return state.bridgeCandidatesHandler
        }
        handler?(port)
    }

    /// The bridge's generated configuration followed by the script.
    var bridgeScriptResponse: Data {
        let ports = shared.withLock { $0.bridgedPorts }.sorted()
        let config = #"window.__opentrafficBridge = {"appPort":\#(configuration.upstreamPort),"ports":[\#(ports.map(String.init).joined(separator: ","))]};"#
        return Data((config + "\n").utf8) + configuration.bridgeScript
    }

    enum UploadResult {
        case stored(String)
        case rejected(HTTPResponseStatus, String)
    }

    /// Stores a screenshot from someone in the session and returns its id. `token` is the upload
    /// token the hub gave that person's connection in `welcome`.
    func storeUpload(_ body: ByteBuffer, contentType: String?, token: String?, now: Date = Date()) -> UploadResult {
        loop.preconditionInEventLoop()
        guard let directory = configuration.attachmentsDirectory else { return .rejected(.notFound, "Uploads are off.") }
        guard let token, let peer = room.connection(forUploadToken: token) else { return .rejected(.forbidden, "Join the session first.") }
        let types = ["image/webp": "webp", "image/jpeg": "jpg", "image/png": "png"]
        guard let type = contentType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let fileExtension = types[type] else { return .rejected(.unsupportedMediaType, "Only WebP, JPEG, and PNG.") }
        guard body.readableBytes > 0, body.readableBytes <= Self.maximumUploadBytes else { return .rejected(.payloadTooLarge, "Too large.") }
        guard Self.looksLike(fileExtension, body) else { return .rejected(.unsupportedMediaType, "That isn't a picture.") }
        let recent = (uploadTimes[peer] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < Self.uploadsPerMinute else { return .rejected(.tooManyRequests, "Too many uploads.") }
        guard attachmentBytes + body.readableBytes <= Self.maximumAttachmentBytes else { return .rejected(.insufficientStorage, "This share has no room for more pictures.") }
        let id = Self.attachmentID()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(body.readableBytesView).write(to: directory.appending(path: "\(id).\(fileExtension)"), options: .atomic)
        } catch {
            return .rejected(.internalServerError, "Couldn't store it.")
        }
        uploadTimes[peer] = recent + [now]
        attachmentBytes += body.readableBytes
        room.registerAttachment(id, from: peer)
        return .stored(id)
    }

    /// Whether `body` starts the way a file of that type does.
    static func looksLike(_ fileExtension: String, _ body: ByteBuffer) -> Bool {
        let bytes = Array(body.readableBytesView.prefix(12))
        switch fileExtension {
        case "png": return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "jpg": return bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case "webp": return bytes.count == 12 && bytes[0..<4].elementsEqual("RIFF".utf8) && bytes[8..<12].elementsEqual("WEBP".utf8)
        default: return false
        }
    }

    /// Removes a stored picture whose comment is gone (deleted, or dropped from a full share).
    private func removeAttachment(_ id: String) {
        guard let directory = configuration.attachmentsDirectory, Self.isAttachmentID(id) else { return }
        for fileExtension in ["webp", "jpg", "png"] {
            let file = directory.appending(path: "\(id).\(fileExtension)")
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at: file)) != nil { attachmentBytes = max(0, attachmentBytes - size) }
        }
    }

    /// An uploaded picture's bytes and type, if `id` names one.
    func attachment(_ id: String) -> (Data, String)? {
        guard let directory = configuration.attachmentsDirectory, Self.isAttachmentID(id) else { return nil }
        for (fileExtension, type) in [("webp", "image/webp"), ("jpg", "image/jpeg"), ("png", "image/png")] {
            if let data = try? Data(contentsOf: directory.appending(path: "\(id).\(fileExtension)")) { return (data, type) }
        }
        return nil
    }

    static func attachmentID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func isAttachmentID(_ id: String) -> Bool {
        id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `/__opentraffic/port/7880/rtc?x=1` → (7880, "/rtc?x=1").
    static func bridgedTarget(_ uri: String) -> (port: Int, rest: String)? {
        guard uri.hasPrefix(bridgedPrefix) else { return nil }
        let remainder = uri.dropFirst(bridgedPrefix.count)
        let digits = remainder.prefix { $0.isNumber }
        guard let port = Int(digits), (1...65_535).contains(port) else { return nil }
        var rest = String(remainder.dropFirst(digits.count))
        if rest.isEmpty || rest.first == "?" { rest = "/" + rest }
        guard rest.first == "/", !rest.hasPrefix("//") else { return nil }
        return (port, rest)
    }

    /// The page's origin as the visitor's browser sees it.
    func pageOrigin(for head: HTTPRequestHead) -> String {
        if isLocalAuthority(head), let host = head.headers.first(name: "host") { return "http://\(host.lowercased())" }
        let publicHost = shared.withLock { $0.publicHost }
        let host = publicHost ?? head.headers.first(name: "host")?.lowercased() ?? "localhost"
        let scheme = head.headers.first(name: "x-forwarded-proto")?.lowercased() == "http" ? "http" : "https"
        return "\(scheme)://\(host)"
    }

    func socketDisconnected(_ id: String) {
        sockets[id] = nil
        socketAddresses[id] = nil
        uploadTimes[id] = nil
        deliver(room.disconnect(id))
        reportPeersIfChanged()
    }

    private func deliver(_ messages: [CollabRoom.Outgoing]) {
        for message in messages {
            let frame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: message.text))
            for (id, channel) in sockets where room.includes(message.target, id) {
                // Cursors move on; a peer that's falling behind doesn't need the old ones.
                if message.isEphemeral, !channel.isWritable { continue }
                channel.writeAndFlush(frame, promise: nil)
            }
        }
    }

    private func reportPeersIfChanged() {
        let peers = room.peers
        guard peers != lastReportedPeers else { return }
        lastReportedPeers = peers
        shared.withLock { $0.peersHandler }?(peers)
    }

    private func reportCommentsIfChanged() {
        let comments = room.comments
        guard comments != lastReportedComments else { return }
        let gone = Set(lastReportedComments.flatMap(\.attachments)).subtracting(comments.flatMap(\.attachments))
        gone.forEach(removeAttachment)
        lastReportedComments = comments
        shared.withLock { $0.commentsHandler }?(comments)
    }

    // MARK: Helpers

    static func path(of uri: String) -> String {
        String(uri.prefix { $0 != "?" && $0 != "#" })
    }

    static func query(_ name: String, in uri: String) -> String? {
        URLComponents(string: uri)?.queryItems?.first { $0.name == name }?.value
    }

    static func cookie(_ name: String, in headers: HTTPHeaders) -> String? {
        for header in headers[canonicalForm: "cookie"] {
            for pair in header.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == name { return parts[1] }
            }
        }
        return nil
    }

    /// The Cookie header without OpenTraffic's own cookies (any whose name starts with `prefix`), so
    /// host tokens never reach the app.
    static func removingCookies(prefix: String, from headers: inout HTTPHeaders) {
        let values = headers[canonicalForm: "cookie"]
        guard !values.isEmpty else { return }
        let kept = values.flatMap { $0.split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix(prefix) && !$0.isEmpty }
        headers.remove(name: "cookie")
        if !kept.isEmpty { headers.add(name: "cookie", value: kept.joined(separator: "; ")) }
    }
}

// MARK: - HTTP proxying

/// One client connection: forwards requests to the local server over one upstream connection,
/// answers OpenTraffic's own routes, and turns into a raw relay for WebSocket upgrades.
private final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let proxy: CollabProxy
    private let encoder: RemovableChannelHandler
    private let decoder: RemovableChannelHandler
    /// HTTP handlers between the decoder and this one.
    private let downstream: [RemovableChannelHandler]
    private var context: ChannelHandlerContext?

    private var upstream: Channel?
    /// The local port `upstream` is connected to.
    private var upstreamPort: Int?
    private var connecting = false
    private var pending: [HTTPClientRequestPart] = []
    /// The local port the current request goes to: the app's, or a bridged one.
    private var targetPort: Int
    /// Set when the current request goes to a bridged port.
    private var bridgedPort: Int?
    private var localBody: ByteBuffer?

    private var request: HTTPRequestHead?
    private var localRoute = false
    /// The current request needs the share's password first.
    private var gate: CollabProxy.AccessGate?
    private var socketUpgrade: HTTPRequestHead?
    /// The current request asks the local server to switch protocols (hot reload, bridged sockets).
    fileprivate private(set) var upgrading = false
    /// The local server's 101, sent on to the client once its response has fully arrived.
    private var switchHead: HTTPResponseHead?
    /// Close the client connection after this response (a refused upgrade: HTTP parsing has stopped).
    private var closeAfterResponse = false
    private var relaying = false
    private var responseStarted = false
    private var injector: HTMLInjector?
    private var upstreamKeepAlive = true

    init(proxy: CollabProxy, encoder: RemovableChannelHandler, decoder: RemovableChannelHandler, downstream: [RemovableChannelHandler]) {
        self.proxy = proxy
        self.encoder = encoder
        self.decoder = decoder
        self.downstream = downstream
        self.targetPort = proxy.configuration.upstreamPort
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !relaying else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            request = head
            responseStarted = false
            injector = nil
            localBody = nil
            bridgedPort = nil
            upgrading = false
            upstreamKeepAlive = true
            targetPort = proxy.configuration.upstreamPort
            let path = CollabProxy.path(of: head.uri)
            let isUpgrade = head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
            gate = proxy.gate(head)
            if gate != nil {
                localRoute = true
                closeAfterResponse = isUpgrade || head.method == .CONNECT
                return
            }
            // CONNECT isn't proxied; like an upgrade, the parser stops after it.
            localRoute = path.hasPrefix("/__opentraffic/") || head.method == .CONNECT
            // The request parser stops after an upgrade request, so unless the protocol actually
            // switches, whatever answers it must be the last thing on this connection.
            closeAfterResponse = isUpgrade || head.method == .CONNECT
            if isUpgrade, path == CollabProxy.socketPath {
                socketUpgrade = head
                return
            }
            var forwarded = upstreamHead(for: head)
            if let electronPort = proxy.configuration.electronHostPort, path.hasPrefix(CollabProxy.electronPrefix) {
                // The app's main process, sandboxed. Its WebSocket only takes this share's pages.
                if isUpgrade, !proxy.acceptsOrigin(head) { return }
                localRoute = false
                bridgedPort = electronPort
                targetPort = electronPort
                forwarded.headers.replaceOrAdd(name: "host", value: "127.0.0.1:\(electronPort)")
            } else if let target = CollabProxy.bridgedTarget(head.uri) {
                guard proxy.allowsBridgedPort(target.port) else {
                    proxy.reportBridgeCandidate(target.port)
                    return // answered as a local route: not bridged (yet)
                }
                localRoute = false
                bridgedPort = target.port
                targetPort = target.port
                forwarded = bridgedHead(forwarded, port: target.port, rest: target.rest, pageOrigin: proxy.pageOrigin(for: head))
            }
            if localRoute { return }
            if isUpgrade {
                // A fresh connection: if the server switches protocols it becomes a relay, and if it
                // refuses, the client still gets its answer over plain HTTP.
                upgrading = true
                if let current = upstream {
                    upstream = nil
                    upstreamPort = nil
                    current.close(promise: nil)
                }
            }
            send(.head(forwarded))
        case .body(var buffer):
            if !localRoute {
                send(.body(.byteBuffer(buffer)))
            } else if gate == .signIn {
                if localBody == nil { localBody = context.channel.allocator.buffer(capacity: buffer.readableBytes) }
                if (localBody?.readableBytes ?? 0) <= 8 * 1024 { localBody?.writeBuffer(&buffer) }
            } else if CollabProxy.path(of: request?.uri ?? "") == CollabProxy.uploadPath {
                // Collect uploads up to a little past the limit, so oversize ones are answered as such.
                if localBody == nil { localBody = context.channel.allocator.buffer(capacity: buffer.readableBytes) }
                if (localBody?.readableBytes ?? 0) <= CollabProxy.maximumUploadBytes { localBody?.writeBuffer(&buffer) }
            }
        case .end(let trailers):
            if let gate {
                self.gate = nil
                respondToGate(gate, context: context)
            } else if let head = socketUpgrade {
                socketUpgrade = nil
                acceptSocket(context: context, head: head)
            } else if localRoute {
                respondLocally(context: context)
            } else {
                send(.end(trailers))
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !relaying { upstream?.close(promise: nil) }
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Simple backpressure: stop reading from the local server while the client is slow.
        upstream?.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in }
        context.fireChannelWritabilityChanged()
    }

    private func upstreamHead(for head: HTTPRequestHead) -> HTTPRequestHead {
        var head = head
        // Uncompressed HTML can be edited on the fly; Cloudflare compresses at the edge anyway.
        if proxy.configuration.injectsOverlay { head.headers.remove(name: "accept-encoding") }
        CollabProxy.removingCookies(prefix: CollabProxy.hostCookiePrefix, from: &head.headers)
        CollabProxy.removingCookies(prefix: ShareAccess.cookieName, from: &head.headers)
        // The share's password, sent by a tool: the app has its own idea of who may sign in.
        if let access = proxy.access, let authorization = head.headers.first(name: "authorization"), access.accepts(authorization: authorization) {
            head.headers.remove(name: "authorization")
        }
        // The host's browser talks to the proxy's own address; give the local server the
        // address it expects, as if it were opened directly.
        if proxy.isLocalAuthority(head) || proxy.configuration.rewritesHostHeader {
            head.headers.replaceOrAdd(name: "host", value: proxy.configuration.upstreamAuthority)
        }
        return head
    }

    /// A request for a bridged local service, shaped as the page would send it without the tunnel.
    /// Only the share's own pages get the app's local origin; others keep theirs, so the service's
    /// own origin checks still turn them away.
    private func bridgedHead(_ head: HTTPRequestHead, port: Int, rest: String, pageOrigin: String) -> HTTPRequestHead {
        var head = head
        head.uri = rest
        head.headers.replaceOrAdd(name: "host", value: "localhost:\(port)")
        if head.headers.first(name: "origin")?.lowercased() == pageOrigin.lowercased() {
            head.headers.replaceOrAdd(name: "origin", value: "http://localhost:\(proxy.configuration.upstreamPort)")
        }
        return head
    }

    // MARK: Upstream

    private func send(_ part: HTTPClientRequestPart) {
        // A request for a different local port needs its own connection.
        if case .head = part, let current = upstream, upstreamPort != targetPort {
            upstream = nil
            upstreamPort = nil
            current.close(promise: nil)
        }
        if let upstream, !connecting {
            upstream.writeAndFlush(part, promise: nil)
            return
        }
        pending.append(part)
        connectUpstream()
    }

    private func connectUpstream() {
        guard !connecting, upstream == nil, let context else { return }
        connecting = true
        let port = targetPort
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // The client handlers are kept so an upgraded connection can drop them; the
                    // decoder hands on bytes that follow a 101 response.
                    let encoder = HTTPRequestEncoder()
                    let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                    let validator = NIOHTTPRequestHeadersValidator()
                    try channel.pipeline.syncOperations.addHandlers([encoder, decoder, validator])
                    try channel.pipeline.syncOperations.addHandler(UpstreamHandler(proxy: bound, httpHandlers: [validator, encoder, decoder]))
                }
            }
            .connect(host: upstreamHost(for: port), port: port)
            .assumeIsolated()
            .whenComplete { [self] result in
                connecting = false
                switch result {
                case .success(let channel):
                    guard self.context != nil else {
                        channel.close(promise: nil)
                        return
                    }
                    upstream = channel
                    upstreamPort = port
                    let parts = pending
                    pending = []
                    for part in parts { channel.write(part, promise: nil) }
                    channel.flush()
                case .failure:
                    pending = []
                    respondUnavailable()
                }
            }
    }

    /// The app on its own address; the Electron host on 127.0.0.1, where it listens; other local
    /// ports of a loopback app by name, so they're found on IPv4 or IPv6.
    private func upstreamHost(for port: Int) -> String {
        let configuration = proxy.configuration
        if port == configuration.upstreamPort { return configuration.upstreamHost }
        if port == configuration.electronHostPort { return "127.0.0.1" }
        return ["127.0.0.1", "::1", "localhost"].contains(configuration.upstreamHost) ? "localhost" : configuration.upstreamHost
    }

    fileprivate func upstreamRead(_ part: HTTPClientResponsePart) {
        guard !relaying, let context, let request else { return }
        switch part {
        case .head(var head):
            if upgrading {
                upgrading = false
                if head.status == .switchingProtocols {
                    // Wait for the end of this response (see `upstreamSwitchedProtocols`).
                    relaying = true
                    switchHead = head
                    return
                }
                // Refused: pass the answer on; both connections close afterwards.
                upstreamKeepAlive = false
            }
            responseStarted = true
            upstreamKeepAlive = upstreamKeepAlive && head.isKeepAlive
            rewriteHeaders(&head.headers)
            if bridgedPort == nil, proxy.configuration.injectsOverlay, Self.shouldInject(request: request, response: head) {
                let nonce = CollabProxy.attachmentID()
                var needsNonce = false
                let origin = proxy.pageOrigin(for: request)
                let policies = head.headers[canonicalForm: "content-security-policy"]
                if !policies.isEmpty {
                    head.headers.remove(name: "content-security-policy")
                    for policy in policies {
                        for port in ContentSecurityPolicyAdjuster.loopbackPorts(in: String(policy)) { proxy.reportBridgeCandidate(port) }
                        let adjusted = ContentSecurityPolicyAdjuster.adjust(String(policy), origin: origin, nonce: nonce)
                        needsNonce = needsNonce || adjusted.needsNonce
                        head.headers.add(name: "content-security-policy", value: adjusted.header)
                    }
                }
                let electron = proxy.configuration.electronHostPort == nil ? "" : CollabProxy.electronTag(nonce: needsNonce ? nonce : nil)
                let injector = HTMLInjector(
                    headStart: CollabProxy.bridgeTag(nonce: needsNonce ? nonce : nil) + electron,
                    headEnd: CollabProxy.overlayTag(nonce: needsNonce ? nonce : nil)
                )
                self.injector = injector
                if let length = head.headers.first(name: "content-length").flatMap(Int.init) {
                    head.headers.replaceOrAdd(name: "content-length", value: String(length + injector.addedLength))
                }
            }
            // Keep-alive on the client side follows the client's request, not the local server.
            head.headers.remove(name: "connection")
            head.headers.remove(name: "keep-alive")
            if !request.isKeepAlive || closeAfterResponse {
                head.headers.add(name: "connection", value: "close")
            } else if request.version.minor == 0 {
                head.headers.add(name: "connection", value: "keep-alive")
            }
            head.version = request.version
            context.write(wrapOutboundOut(.head(head)), promise: nil)
        case .body(var buffer):
            if injector != nil {
                let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                let output = injector!.feed(bytes)
                if !output.isEmpty {
                    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: output)))), promise: nil)
                }
            } else {
                context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
        case .end(let trailers):
            if injector != nil {
                let output = injector!.finish()
                if !output.isEmpty {
                    context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: output)))), promise: nil)
                }
            }
            finishResponse(context: context, trailers: trailers)
            if !upstreamKeepAlive {
                upstream?.close(promise: nil)
                upstream = nil
            }
        }
    }

    fileprivate func upstreamClosed(_ channel: Channel) {
        guard upstream === channel else { return }
        upstream = nil
        guard request != nil, !localRoute else { return }
        if responseStarted {
            // Cut off mid-response: the client can't tell where the body ends otherwise.
            context?.close(promise: nil)
        } else {
            respondUnavailable()
        }
    }

    private func finishResponse(context: ChannelHandlerContext, trailers: HTTPHeaders?) {
        let keepAlive = (request?.isKeepAlive ?? false) && !closeAfterResponse
        closeAfterResponse = false
        request = nil
        injector = nil
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(trailers))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    /// Redirects to local services stay on the share; cookies scoped to localhost move to the tunnel host.
    private func rewriteHeaders(_ headers: inout HTTPHeaders) {
        let rewriter = LoopbackURLRewriter(appPort: proxy.configuration.upstreamPort, bridgedPorts: proxy.bridgedPorts)
        if let location = headers.first(name: "location"), let rewritten = rewriter.location(location, bridgedFrom: bridgedPort) {
            headers.replaceOrAdd(name: "location", value: rewritten)
        }
        let cookies = headers[canonicalForm: "set-cookie"]
        if !cookies.isEmpty {
            headers.remove(name: "set-cookie")
            for cookie in cookies { headers.add(name: "set-cookie", value: LoopbackURLRewriter.setCookie(String(cookie))) }
        }
    }

    static func shouldInject(request: HTTPRequestHead, response: HTTPResponseHead) -> Bool {
        guard request.method == .GET,
              response.status.code >= 200, response.status != .noContent, response.status != .notModified,
              let type = response.headers.first(name: "content-type")?.lowercased(),
              type.hasPrefix("text/html") else { return false }
        let encoding = response.headers.first(name: "content-encoding")?.lowercased() ?? "identity"
        return encoding == "identity"
    }

    // MARK: OpenTraffic's own routes

    private func respondLocally(context: ChannelHandlerContext) {
        guard let request else { return }
        let path = CollabProxy.path(of: request.uri)
        if let target = CollabProxy.bridgedTarget(request.uri) {
            let message = "OpenTraffic hasn't been allowed to reach localhost:\(target.port) for this share. Allow it in OpenTraffic's Live Collaboration card.\n"
            respond(context: context, status: .forbidden, headers: HTTPHeaders(), body: ByteBuffer(string: message))
            return
        }
        if request.method == .GET, path.hasPrefix(CollabProxy.attachmentsPrefix) {
            let id = String(path.dropFirst(CollabProxy.attachmentsPrefix.count))
            guard let (data, type) = proxy.attachment(id) else {
                respond(context: context, status: .notFound, headers: HTTPHeaders(), body: ByteBuffer(string: "Not found\n"))
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: type)
            headers.add(name: "cache-control", value: "private, max-age=86400")
            headers.add(name: "x-content-type-options", value: "nosniff")
            respond(context: context, status: .ok, headers: headers, body: ByteBuffer(bytes: data))
            return
        }
        switch (request.method, path) {
        case (.GET, CollabProxy.bridgePath):
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/javascript; charset=utf-8")
            headers.add(name: "cache-control", value: "no-cache")
            respond(context: context, status: .ok, headers: headers, body: ByteBuffer(bytes: proxy.bridgeScriptResponse))
        case (.POST, CollabProxy.bridgeWantPath):
            if let port = CollabProxy.query("port", in: request.uri).flatMap(Int.init) { proxy.reportBridgeCandidate(port) }
            respond(context: context, status: .noContent, headers: HTTPHeaders(), body: ByteBuffer())
        case (.POST, CollabProxy.uploadPath):
            let result = proxy.storeUpload(
                localBody ?? ByteBuffer(),
                contentType: request.headers.first(name: "content-type"),
                token: request.headers.first(name: "x-opentraffic-upload-token")
            )
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            switch result {
            case .stored(let id):
                respond(context: context, status: .created, headers: headers, body: ByteBuffer(string: #"{"id":"\#(id)"}"#))
            case .rejected(let status, let message):
                let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
                respond(context: context, status: status, headers: headers, body: ByteBuffer(bytes: body))
            }
        case (.GET, CollabProxy.scriptPath):
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/javascript; charset=utf-8")
            headers.add(name: "cache-control", value: "no-cache")
            respond(context: context, status: .ok, headers: headers, body: ByteBuffer(bytes: proxy.configuration.overlayScript))
        case (.GET, CollabProxy.hostPath)
            where proxy.isLocalAuthority(request) && CollabProxy.query("token", in: request.uri) == proxy.hostToken:
            var headers = HTTPHeaders()
            headers.add(name: "location", value: "/")
            headers.add(name: "set-cookie", value: "\(proxy.hostCookie)=\(proxy.hostToken); Path=/; HttpOnly; SameSite=Strict")
            headers.add(name: "cache-control", value: "no-store")
            respond(context: context, status: .found, headers: headers, body: ByteBuffer())
        case (_, CollabProxy.hostPath):
            respond(context: context, status: .forbidden, headers: HTTPHeaders(), body: ByteBuffer(string: "Forbidden\n"))
        default:
            respond(context: context, status: .notFound, headers: HTTPHeaders(), body: ByteBuffer(string: "Not found\n"))
        }
    }

    // MARK: Password

    private func respondToGate(_ gate: CollabProxy.AccessGate, context: ChannelHandlerContext) {
        guard let request else { return }
        let shareName = proxy.access?.shareName ?? "Shared site"
        let asksName = proxy.configuration.injectsOverlay
        var headers = HTTPHeaders(ShareAccess.pageHeaders)
        switch gate {
        case .signInPage(let next):
            let status: HTTPResponseStatus = CollabProxy.path(of: request.uri) == ShareAccess.signInPath ? .ok : .unauthorized
            respond(context: context, status: status, headers: headers, body: ByteBuffer(string: ShareAccess.signInPage(shareName: shareName, next: next, asksName: asksName)))
        case .signIn:
            let fields = ShareAccess.formFields(localBody.map { Data($0.readableBytesView) } ?? Data())
            let next = ShareAccess.safeNext(fields["next"])
            switch proxy.signIn(password: fields["password"] ?? "", from: request.headers.first(name: "cf-connecting-ip")) {
            case .accepted(let access):
                headers.add(name: "set-cookie", value: access.setCookieHeader)
                respond(context: context, status: .ok, headers: headers, body: ByteBuffer(string: ShareAccess.signedInPage(next: next, name: fields["name"])))
            case .wrong:
                let page = ShareAccess.signInPage(shareName: shareName, next: next, error: "That password isn't right.", asksName: asksName)
                respond(context: context, status: .unauthorized, headers: headers, body: ByteBuffer(string: page))
            case .limited:
                headers.add(name: "retry-after", value: String(Int(SignInLimiter.window)))
                let page = ShareAccess.signInPage(shareName: shareName, next: next, error: "Too many tries. Wait a minute, then try again.", asksName: asksName)
                respond(context: context, status: .tooManyRequests, headers: headers, body: ByteBuffer(string: page))
            }
        case .invite(let next):
            var headers = HTTPHeaders()
            headers.add(name: "location", value: next)
            headers.add(name: "cache-control", value: "no-store")
            headers.add(name: "referrer-policy", value: "no-referrer")
            if let access = proxy.access { headers.add(name: "set-cookie", value: access.setCookieHeader) }
            respond(context: context, status: .seeOther, headers: headers, body: ByteBuffer())
        case .refused:
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "text/plain; charset=utf-8")
            headers.add(name: "www-authenticate", value: #"Basic realm="OpenTraffic", charset="UTF-8""#)
            headers.add(name: "cache-control", value: "no-store")
            respond(context: context, status: .unauthorized, headers: headers, body: ByteBuffer(string: "This share is password protected.\n"))
        }
    }

    private func respondUnavailable() {
        guard let context, request != nil, !responseStarted else { return }
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/html; charset=utf-8")
        let page = """
        <!doctype html><meta charset="utf-8"><title>Local server not responding</title>
        <body style="font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#333">
        <h1 style="font-size:1.3rem">The local server isn't responding</h1>
        <p>OpenTraffic is sharing this site, but nothing answered on the computer running it. Start the development server and reload.</p>
        """
        respond(context: context, status: .badGateway, headers: headers, body: ByteBuffer(string: page))
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer) {
        responseStarted = true
        var headers = headers
        headers.replaceOrAdd(name: "content-length", value: String(body.readableBytes))
        if request?.isKeepAlive == false || closeAfterResponse { headers.replaceOrAdd(name: "connection", value: "close") }
        let head = HTTPResponseHead(version: request?.version ?? .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if body.readableBytes > 0 { context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil) }
        localBody = nil
        finishResponse(context: context, trailers: nil)
    }

    // MARK: Relay after an upgrade (hot reload, bridged WebSockets)

    /// The local server switched protocols and its 101 response is complete: pass the 101 on, then
    /// turn both connections into a byte relay. `upstreamHandler` holds back anything that arrives
    /// in the meantime.
    fileprivate func upstreamSwitchedProtocols(_ upstreamHandler: UpstreamHandler, upstreamChannel: Channel) {
        guard let context, var head = switchHead else {
            upstreamChannel.close(promise: nil)
            return
        }
        switchHead = nil
        upstream = nil
        let inbound = context.channel
        head.version = request?.version ?? head.version
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { [self] result in
            do {
                guard case .success = result else { throw ChannelError.ioOnClosedChannel }
                try replaceHTTPHandlers(context: context, with: [RawRelayHandler(peer: upstreamChannel)])
                upstreamHandler.becomeRelay(to: inbound)
            } catch {
                inbound.close(promise: nil)
                upstreamChannel.close(promise: nil)
            }
        }
    }

    /// Swaps this connection's HTTP handlers for `handlers` (added at the end, inbound side) and an
    /// optional outbound `encoder`. Everything after the request decoder goes first and the decoder
    /// last, so bytes it still holds are forwarded straight to the new handlers.
    private func replaceHTTPHandlers(context: ChannelHandlerContext, with handlers: [ChannelHandler], encoder outbound: ChannelHandler? = nil) throws {
        let sync = context.pipeline.syncOperations
        for handler in downstream { _ = sync.removeHandler(handler) }
        try sync.addHandlers(handlers)
        if let outbound { try sync.addHandler(outbound, position: .first) }
        _ = sync.removeHandler(self)
        _ = sync.removeHandler(decoder)
        _ = sync.removeHandler(encoder)
    }

    // MARK: Hub WebSocket

    private func acceptSocket(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard proxy.acceptsSocket(head),
              head.headers.first(name: "sec-websocket-version") == "13",
              let key = head.headers.first(name: "sec-websocket-key"), !key.isEmpty else {
            request = head
            respond(context: context, status: .forbidden, headers: HTTPHeaders(), body: ByteBuffer(string: "Forbidden\n"))
            return
        }
        let isHost = proxy.isHost(head)
        // Behind the tunnel every visitor comes from 127.0.0.1; Cloudflare says who they are.
        // A full session still switches protocols: browsers only see a WebSocket's close code
        // (1013, "Session is full"), not an HTTP refusal. SocketHandler turns it away.
        let address = head.headers.first(name: "cf-connecting-ip") ?? context.channel.remoteAddress?.ipAddress ?? "?"
        relaying = true
        var headers = HTTPHeaders()
        headers.add(name: "upgrade", value: "websocket")
        headers.add(name: "connection", value: "Upgrade")
        headers.add(name: "sec-websocket-accept", value: CollabProxy.webSocketAccept(for: key))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .switchingProtocols, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { [self] result in
            guard case .success = result, self.context != nil else {
                context.close(promise: nil)
                return
            }
            do {
                try replaceHTTPHandlers(
                    context: context,
                    with: [
                        ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 16 * 1024)),
                        WebSocketProtocolErrorHandler(),
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1,
                            maxAccumulatedFrameCount: 16,
                            maxAccumulatedFrameSize: CollabRoom.maximumFrameBytes
                        ),
                        SocketHandler(proxy: proxy, isHost: isHost, address: address),
                    ],
                    encoder: WebSocketFrameEncoder()
                )
            } catch {
                context.close(promise: nil)
            }
        }
    }

}

private final class UpstreamHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let proxy: NIOLoopBound<ProxyHandler>
    /// The HTTP client handlers before this one, in the order to remove them (decoder last).
    let httpHandlers: [RemovableChannelHandler]
    private var context: ChannelHandlerContext?
    private var awaitingEndOfSwitch = false
    /// After a 101 response: everything that follows is held here, unread, until the relay is in place.
    private var holding = false
    private var held: [NIOAny] = []

    init(proxy: NIOLoopBound<ProxyHandler>, httpHandlers: [RemovableChannelHandler]) {
        self.proxy = proxy
        self.httpHandlers = httpHandlers
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if holding {
            held.append(data)
            return
        }
        let part = unwrapInboundIn(data)
        if case .head(let head) = part, head.status == .switchingProtocols, proxy.value.upgrading {
            awaitingEndOfSwitch = true
        }
        if awaitingEndOfSwitch, case .end = part {
            holding = true
            proxy.value.upstreamSwitchedProtocols(self, upstreamChannel: context.channel)
            return
        }
        proxy.value.upstreamRead(part)
    }

    /// Drops the HTTP handlers (the decoder's leftover bytes land in `held`), puts a relay to `peer`
    /// after this handler, passes on what was held, and leaves the pipeline.
    func becomeRelay(to peer: Channel) {
        guard let context else { return }
        let sync = context.pipeline.syncOperations
        do {
            try sync.addHandler(RawRelayHandler(peer: peer), position: .after(self))
            for handler in httpHandlers { _ = sync.removeHandler(handler) }
            let pending = held
            held = []
            for data in pending { context.fireChannelRead(data) }
            if !pending.isEmpty { context.fireChannelReadComplete() }
            _ = sync.removeHandler(context: context)
        } catch {
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        proxy.value.upstreamClosed(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Copies bytes to the other side of a relayed connection and closes both together.
private final class RawRelayHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Hub connections

private final class SocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let proxy: CollabProxy
    private let isHost: Bool
    private let address: String
    private var id: String?
    private var keepAlive: RepeatedTask?

    init(proxy: CollabProxy, isHost: Bool, address: String) {
        self.proxy = proxy
        self.isHost = isHost
        self.address = address
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard let id = proxy.socketConnected(context.channel, isHost: isHost, address: address) else {
            // Full. Close once the pipeline swap is over, when the WebSocket encoder is in place;
            // writing the close frame from here would reach the HTTP encoder and stop the app.
            let channel = context.channel
            context.eventLoop.execute { Self.close(channel, code: .unknown(1013)) }
            return
        }
        self.id = id
        let channel = context.channel
        context.eventLoop.scheduleTask(in: CollabProxy.helloTimeout) { [proxy] in
            if !proxy.socketIsJoined(id) { Self.close(channel, code: .policyViolation) }
        }
        // Cloudflare drops WebSockets idle for 100 seconds.
        keepAlive = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(30), delay: .seconds(30)) { _ in
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            guard let id else { return }
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            proxy.socketReceived(text, from: id)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            close(context: context, code: .normalClosure)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        keepAlive?.cancel()
        keepAlive = nil
        if let id {
            self.id = nil
            proxy.socketDisconnected(id)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func close(context: ChannelHandlerContext, code: WebSocketErrorCode) {
        Self.close(context.channel, code: code)
    }

    private static func close(_ channel: Channel, code: WebSocketErrorCode) {
        var data = channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: code)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

/// Attachment ids as the proxy issues them.
public enum CollabProxyAttachment {
    public static func isValid(_ id: String) -> Bool {
        CollabProxy.isAttachmentID(id)
    }
}
