import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One frame of a captured window, ready to send: `header` is the `frame` message, `tiles` the binary
/// messages that follow it (MirrorProtocol). A full frame is one tile covering the whole window.
public struct CapturedFrame: Equatable, Sendable {
    public var window: MirrorProtocol.WindowID
    public var seq: UInt32
    /// The tiles cover the whole window: the first frame, after a resize, or on request.
    public var full: Bool
    /// The window's size in points.
    public var width: Int
    public var height: Int
    /// Pixels per point in the tiles' images.
    public var scale: Double
    public var tiles: [MirrorProtocol.Tile]
    /// Time spent comparing and encoding this frame on the capture queue.
    public var encodeTime: Duration

    public var header: MirrorProtocol.FrameHeader { .init(window: window, seq: seq, full: full, tiles: tiles.count) }
    public var byteCount: Int { tiles.reduce(0) { $0 + $1.data.count } }
}

public enum WindowCaptureError: Error, Equatable, Sendable {
    case notPermitted
    case windowNotFound(CGWindowID)
    case snapshotFailed
    /// ScreenCaptureKit did not answer in time (it can hang when replayd is busy).
    case timedOut
}

/// Streams one window through ScreenCaptureKit and emits a `CapturedFrame` only when its pixels changed.
///
/// SCStream's own change reporting is not enough: it delivers complete frames with whole-window dirty
/// rects when nothing changed (and again about a second after each change), and now and then none
/// for a real change. So every complete frame is compared with the pixels the viewers have, in
/// 16-point cells, ignoring differences of one level (`tolerance`); changed cells become tiles,
/// neighbours and rects within 8 points of each other merged, more than 12 tiles sending a full frame
/// instead. After a quiet second the stream is nudged for a fresh frame, so a lost change arrives
/// late rather than never. A resize is noticed from the frame's content rect and scale, the stream
/// is reconfigured to the new size, and the next frame is full. `frames` finishes when the window
/// closes or `stop()` is called.
///
/// The window has to be rendered by the window server: a window entirely outside every display, or
/// with alpha 0, gets no frames. A window ordered below the desktop (level `kCGDesktopWindowLevel - 1`)
/// is invisible and still captured, with exact dirty rects.
public final class WindowCapture: @unchecked Sendable {
    /// Merged tiles beyond this count send a full frame instead.
    public static let maximumTiles = 12
    /// Changes are found in square cells of this many points.
    public static let cellSize = 16
    /// Changed rects closer than this many points become one tile.
    public static let mergeGap = 8
    public static let jpegQuality = 0.85
    /// Channel differences up to this many levels don't count as a change. Window servers re-render
    /// whole windows with a third of the pixels one level off (seen on idle SwiftUI windows), which is
    /// invisible and well under JPEG's own error, but would otherwise send a full frame each time.
    public static let tolerance: UInt8 = 1

    public let windowID: CGWindowID
    /// The id written into frames and tiles (defaults to the window id).
    public let mirrorWindow: MirrorProtocol.WindowID
    public let format: MirrorProtocol.TileFormat
    public let frames: AsyncStream<CapturedFrame>

    private let requestedScale: Double?
    private let background: CGColor
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    /// Everything below is touched only on `queue` (SCStream delivers samples there).
    private let queue = DispatchQueue(label: "se.medda.opentraffic.window-capture", qos: .userInteractive)
    private let output = Output()
    private var stream: SCStream?
    private var liveness: DispatchSourceTimer?
    private var configuration = SCStreamConfiguration()
    private var filter: SCContentFilter?
    private var pointWidth = 0
    private var pointHeight = 0
    private var scale = 2.0
    private var previous: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0
    private var seq: UInt32 = 0
    private var needsFull = true
    private var reconfiguring = false
    /// For `refreshIfQuiet`: when SCStream last delivered a complete frame, whether a change was sent
    /// since the last refresh, when that refresh was asked for, and whether it is still running.
    private var lastDelivery = ContinuousClock.now
    private var refreshArmed = false
    private var refreshedAt: ContinuousClock.Instant?
    private var refreshing = false
    private let finished = OSAllocatedUnfairLock(initialState: false)

    private static let log = Logger(subsystem: "se.medda.opentraffic", category: "macapp-capture")

    /// - Parameters:
    ///   - scale: pixels per point; `nil` uses the backing scale of the window's display.
    ///   - background: painted behind transparent pixels (rounded corners), since JPEG has no alpha.
    ///   - format: `.webp` falls back to JPEG when this macOS cannot encode WebP.
    public init(windowID: CGWindowID, scale: Double? = nil, background: CGColor = CGColor(gray: 1, alpha: 1),
                format: MirrorProtocol.TileFormat = .jpeg, mirrorWindow: MirrorProtocol.WindowID? = nil) {
        self.windowID = windowID
        self.mirrorWindow = mirrorWindow ?? windowID
        self.requestedScale = scale
        self.background = background
        self.format = format == .webp && Self.canEncodeWebP ? .webp : .jpeg
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(8))
        output.owner = self
    }

    deinit { liveness?.cancel(); continuation.finish() }

    // MARK: Permission and formats

    /// Screen Recording permission for this process (or the terminal that runs it).
    public static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for Screen Recording permission (shows the system prompt the first time); true if granted.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public static let canEncodeWebP: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains("org.webmproject.webp")
    }()

    // MARK: Lifecycle

    /// Finds the window and starts the stream; the first frame (full) follows shortly.
    public func start() async throws {
        guard Self.isPermitted else { throw WindowCaptureError.notPermitted }
        let (window, filter) = try await Self.lookUp(windowID)
        let scale = requestedScale ?? Double(filter.pointPixelScale)
        let size = Self.windowSize(windowID) ?? window.frame.size
        let configuration = Self.configuration(points: size, scale: scale)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.filter = filter
            self.configuration = configuration
            self.scale = scale
            pointWidth = Int(size.width.rounded())
            pointHeight = Int(size.height.rounded())
            needsFull = true
            self.stream = stream
        }
        nonisolated(unsafe) let starting = stream
        do {
            try await Self.within(.seconds(10)) { try await starting.startCapture() }
        } catch {
            // Don't leave a stream that may still start later feeding this capture.
            queue.sync { if self.stream === stream { self.stream = nil } }
            Task { _ = try? await Self.within(.seconds(2)) { try await starting.stopCapture() } }
            throw error
        }

        // SCStream doesn't report a closed window as an error (one `suspended` frame, then silence),
        // so check that the window still exists, on such frames and twice a second.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.finishIfWindowClosed()
            self?.refreshIfQuiet()
        }
        queue.sync { liveness = timer }
        timer.resume()
    }

    /// ScreenCaptureKit calls can wait forever (`startCapture()` for a window the window server hasn't
    /// sized yet, any call while replayd is swamped): give up after `timeout` with `timedOut`, leaving
    /// the call to finish on its own.
    static func within<T>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = OSAllocatedUnfairLock(initialState: false)
        let result = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Unchecked<T>, Error>) in
            @Sendable func resume(_ result: Result<Unchecked<T>, Error>) {
                if once.withLock({ resumed in defer { resumed = true }; return !resumed }) { done.resume(with: result) }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                resume(.failure(WindowCaptureError.timedOut))
            }
            Task {
                do { resume(.success(Unchecked(value: try await operation()))) } catch { resume(.failure(error)) }
                timer.cancel()
            }
        }
        return result.value
    }

    /// ScreenCaptureKit's objects aren't Sendable; they only pass from the call to its caller.
    struct Unchecked<T>: @unchecked Sendable { let value: T }

    /// Stops the stream and finishes `frames`.
    public func stop() async {
        let stream: SCStream? = queue.sync { defer { self.stream = nil }; return self.stream }
        nonisolated(unsafe) let stopping = stream
        _ = try? await Self.within(.seconds(2)) { try await stopping?.stopCapture() }
        finish()
    }

    /// A full frame of what the viewers have now, without waiting for a change (for a viewer that just
    /// joined). It reuses the current `seq` and is not sent into `frames`; nil before the first frame.
    public func fullFrame() async -> CapturedFrame? {
        await withCheckedContinuation { done in
            queue.async {
                guard !self.previous.isEmpty else { return done.resume(returning: nil) }
                let started = ContinuousClock.now
                let frame = self.previous.withUnsafeBytes { pixels in
                    self.makeFrame(pixels: pixels.baseAddress!, bytesPerRow: self.previousWidth * 4, width: self.previousWidth,
                                   height: self.previousHeight, rects: nil, seq: self.seq, started: started)
                }
                done.resume(returning: frame)
            }
        }
    }

    // MARK: Snapshot

    /// The window's current contents as one image at its display's backing scale (for comment
    /// screenshots and tests). Throws `notPermitted`, `windowNotFound`, `snapshotFailed` or `timedOut`.
    public static func snapshot(windowID: CGWindowID) async throws -> CGImage {
        guard isPermitted else { throw WindowCaptureError.notPermitted }
        let (window, filter) = try await lookUp(windowID)
        let size = windowSize(windowID) ?? window.frame.size
        let configuration = Self.configuration(points: size, scale: Double(filter.pointPixelScale))
        do {
            nonisolated(unsafe) let request = (filter, configuration)
            return try await within(.seconds(10)) {
                Unchecked(value: try await SCScreenshotManager.captureImage(contentFilter: request.0, configuration: request.1))
            }.value
        } catch WindowCaptureError.timedOut {
            throw WindowCaptureError.timedOut
        } catch {
            throw WindowCaptureError.snapshotFailed
        }
    }

    // MARK: Stream setup

    /// A window shown a moment ago can be listed with an empty frame, and a filter made from it never
    /// starts: wait (up to 2 s) until the window server has sized it.
    private static func lookUp(_ windowID: CGWindowID) async throws -> (SCWindow, SCContentFilter) {
        for attempt in 0..<20 {
            let content = try await within(.seconds(10)) {
                Unchecked(value: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))
            }.value
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw WindowCaptureError.windowNotFound(windowID)
            }
            if !window.frame.isEmpty || attempt == 19 { return (window, SCContentFilter(desktopIndependentWindow: window)) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WindowCaptureError.windowNotFound(windowID)
    }

    /// The window's bounds from the window server (SCWindow.frame can be a point short on each side).
    static func windowSize(_ windowID: CGWindowID) -> CGSize? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
        return rect.size
    }

    private static func configuration(points: CGSize, scale: Double) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((points.width * scale).rounded()))
        configuration.height = max(1, Int((points.height * scale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return configuration
    }

    // MARK: Frames (on `queue`)

    fileprivate func receive(_ sample: CMSampleBuffer) {
        guard !finished.withLock({ $0 }), !reconfiguring,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .stopped || status == .suspended || status == .blank { return finishIfWindowClosed() }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sample),
              let contentRect = (info[.contentRect] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
              contentRect.width > 0, contentRect.height > 0 else { return }
        lastDelivery = .now
        // The first frame after a refresh is its answer: what it finds doesn't ask for another.
        let answersRefresh = refreshedAt.map { ContinuousClock.now - $0 < .milliseconds(500) } ?? false
        refreshedAt = nil
        let contentScale = (info[.contentScale] as? Double) ?? 1
        let scaleFactor = (info[.scaleFactor] as? Double) ?? scale

        // The window's real size: the content is scaled down to fit the configured size until we follow it.
        let points = CGSize(width: contentRect.width / contentScale, height: contentRect.height / contentScale)
        let size = (width: Int(points.width.rounded()), height: Int(points.height.rounded()))
        if size.width != pointWidth || size.height != pointHeight {
            return resize(to: size)
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let originX = Int((contentRect.minX * scaleFactor).rounded()), originY = Int((contentRect.minY * scaleFactor).rounded())
        let width = min(Int((contentRect.width * scaleFactor).rounded()), CVPixelBufferGetWidth(buffer) - originX)
        let height = min(Int((contentRect.height * scaleFactor).rounded()), CVPixelBufferGetHeight(buffer) - originY)
        guard width > 0, height > 0 else { return }
        let sent = process(pixels: UnsafeRawPointer(base) + originY * bytesPerRow + originX * 4, bytesPerRow: bytesPerRow, width: width, height: height)
        // Only partial frames arm a refresh: the window server's own whole-window re-renders (and the
        // refresh's) come as full frames, and arming on those would refresh back and forth forever.
        if let sent, !sent.full, !answersRefresh { refreshArmed = true }
    }

    /// Compares a frame (BGRA, sRGB, `width` x `height` pixels) with the last one and sends what
    /// changed, if anything.
    private func process(pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int) -> CapturedFrame? {
        let started = ContinuousClock.now

        var rects: [TileRect]?
        if !needsFull, !previous.isEmpty, previousWidth == width, previousHeight == height {
            // The whole frame, not just SCStream's dirty rects: those are relative to the last frame it
            // delivered, so after a dropped frame they could miss a change and leave stale pixels.
            let cells = previous.withUnsafeBytes { old in
                Self.changedCells(current: pixels, currentBytesPerRow: bytesPerRow, previous: old.baseAddress!,
                                  previousBytesPerRow: width * 4, width: width, height: height,
                                  cellPixels: max(1, Int((Double(Self.cellSize) * Double(width) / Double(pointWidth)).rounded())),
                                  tolerance: Self.tolerance)
            }
            let tiles = Self.tiles(for: cells, pointWidth: pointWidth, pointHeight: pointHeight)
            if tiles.isEmpty { return nil } // nothing changed: SCStream repeated the last frame
            rects = tiles.count > Self.maximumTiles ? nil : tiles
        }

        // Keep the pixels the viewers now have, to compare the next frame with: only the sent rects, so
        // differences under the tolerance elsewhere can't add up unseen.
        if previousWidth != width || previousHeight != height || previous.count != width * height * 4 {
            previous = [UInt8](repeating: 0, count: width * height * 4)
        }
        let sent = (rects ?? [TileRect(x: 0, y: 0, w: pointWidth, h: pointHeight)]).map { pixelRect($0, width: width, height: height) }
        previous.withUnsafeMutableBytes { copy in
            for area in sent where area.w > 0 && area.h > 0 {
                for row in area.y..<(area.y + area.h) {
                    copy.baseAddress!.advanced(by: row * width * 4 + area.x * 4)
                        .copyMemory(from: pixels + row * bytesPerRow + area.x * 4, byteCount: area.w * 4)
                }
            }
        }
        previousWidth = width
        previousHeight = height
        needsFull = false
        seq &+= 1

        let frame = previous.withUnsafeBytes { copy in
            makeFrame(pixels: copy.baseAddress!, bytesPerRow: width * 4, width: width, height: height, rects: rects, seq: seq, started: started)
        }
        guard let frame else { return nil }
        Self.log.debug("window \(self.windowID) seq \(frame.seq) \(frame.full ? "full" : "tiles", privacy: .public) \(frame.tiles.count) \(frame.byteCount) bytes in \(frame.encodeTime.milliseconds, format: .fixed(precision: 1)) ms")
        continuation.yield(frame)
        return frame
    }

    /// A rect in points as whole pixels of a `width` x `height` frame.
    private func pixelRect(_ rect: TileRect, width: Int, height: Int) -> TileRect {
        let scale = Double(width) / Double(max(1, pointWidth))
        let x = Int((Double(rect.x) * scale).rounded()), y = Int((Double(rect.y) * scale).rounded())
        return TileRect(x: x, y: y, w: min(width, Int((Double(rect.maxX) * scale).rounded())) - x,
                        h: min(height, Int((Double(rect.maxY) * scale).rounded())) - y)
    }

    /// SCStream sometimes loses a change (seen under heavy load, with a window below the desktop): the
    /// window server has the new pixels, the stream stays silent until something else changes. So once
    /// after each burst of (partial) changes, and while a full frame is owed (first frame, resize), when
    /// the stream has been quiet for a second, reconfigure it (queue depth 3 <-> 4; an identical
    /// configuration is ignored after the first time), which makes it deliver a fresh complete frame.
    /// That frame goes through the same comparison, and a lost change arrives a second or two late
    /// instead of never. Only once per burst, never while idle: the fresh render of a real window can
    /// differ from the incremental one in a thousand scattered pixels, which costs a full frame. (A
    /// screenshot instead would not do: its pixels differ slightly from the stream's for real windows,
    /// so every refresh would send a full frame.)
    private func refreshIfQuiet() {
        guard refreshArmed || needsFull, !finished.withLock({ $0 }), !reconfiguring, !refreshing, let stream,
              ContinuousClock.now - lastDelivery >= .seconds(1) else { return }
        refreshArmed = false
        refreshing = true
        refreshedAt = .now
        configuration.queueDepth = configuration.queueDepth == 3 ? 4 : 3
        nonisolated(unsafe) let request = (stream, configuration)
        Task { [self] in
            _ = try? await Self.within(.seconds(3)) { try await request.0.updateConfiguration(request.1) }
            queue.async { [self] in refreshing = false }
        }
    }

    /// Encodes the given rects (points) of a packed BGRA image, or the whole window when `rects` is nil.
    private func makeFrame(pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, rects: [TileRect]?,
                           seq: UInt32, started: ContinuousClock.Instant) -> CapturedFrame? {
        let rects = rects ?? [TileRect(x: 0, y: 0, w: pointWidth, h: pointHeight)]
        let pixelScale = Double(width) / Double(max(1, pointWidth))
        var tiles: [MirrorProtocol.Tile] = []
        for rect in rects {
            let area = pixelRect(rect, width: width, height: height)
            guard area.w > 0, area.h > 0,
                  let data = Self.encode(pixels: pixels + area.y * bytesPerRow + area.x * 4, bytesPerRow: bytesPerRow, width: area.w, height: area.h,
                                         background: background, format: format) else { return nil }
            tiles.append(MirrorProtocol.Tile(window: mirrorWindow, seq: seq, x: UInt16(clamping: rect.x), y: UInt16(clamping: rect.y),
                                             w: UInt16(clamping: rect.w), h: UInt16(clamping: rect.h), format: format, data: data))
        }
        let full = rects.count == 1 && rects[0] == TileRect(x: 0, y: 0, w: pointWidth, h: pointHeight)
        return CapturedFrame(window: mirrorWindow, seq: seq, full: full, width: pointWidth, height: pointHeight,
                             scale: pixelScale, tiles: tiles, encodeTime: ContinuousClock.now - started)
    }

    /// Follows a resize: new output size, then a full frame. Falls back to a new stream if the
    /// running one refuses the new configuration.
    private func resize(to size: (width: Int, height: Int)) {
        guard let stream, let filter, size.width > 0, size.height > 0 else { return }
        reconfiguring = true
        pointWidth = size.width
        pointHeight = size.height
        needsFull = true
        let configuration = Self.configuration(points: CGSize(width: size.width, height: size.height), scale: scale)
        self.configuration = configuration
        nonisolated(unsafe) let running = stream
        nonisolated(unsafe) let request = (filter, configuration)
        Task { [self, output] in
            do {
                try await Self.within(.seconds(3)) { try await running.updateConfiguration(request.1) }
            } catch {
                Self.log.info("window \(self.windowID): reconfigure failed (\(error.localizedDescription, privacy: .public)); restarting the stream")
                try? await Self.within(.seconds(2)) { try await running.stopCapture() }
                let replacement = SCStream(filter: request.0, configuration: request.1, delegate: output)
                nonisolated(unsafe) let starting = replacement
                do {
                    try replacement.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
                    try await Self.within(.seconds(5)) { try await starting.startCapture() }
                    queue.sync { self.stream = starting }
                } catch {
                    return finish()
                }
            }
            queue.async { self.reconfiguring = false }
        }
    }

    /// On `queue`: the window is gone, so stop the stream and finish `frames`.
    private func finishIfWindowClosed() {
        guard !finished.withLock({ $0 }), Self.windowSize(windowID) == nil else { return }
        let stream = self.stream
        self.stream = nil
        nonisolated(unsafe) let closed = stream
        Task { _ = try? await Self.within(.seconds(2)) { try await closed?.stopCapture() } }
        finish()
    }

    /// Safe from any thread, including `queue` (a `stopped` frame).
    fileprivate func finish() {
        queue.async { [weak self] in self?.liveness?.cancel(); self?.liveness = nil }
        let wasFinished = finished.withLock { finished in defer { finished = true }; return finished }
        if !wasFinished { continuation.finish() }
    }

    // MARK: Change detection (pure, for tests)

    /// A rect in whole points from the window's top-left.
    struct TileRect: Equatable, Sendable {
        var x: Int, y: Int, w: Int, h: Int
        var maxX: Int { x + w }
        var maxY: Int { y + h }
        func union(_ other: TileRect) -> TileRect {
            let minX = min(x, other.x), minY = min(y, other.y)
            return TileRect(x: minX, y: minY, w: max(maxX, other.maxX) - minX, h: max(maxY, other.maxY) - minY)
        }
        /// Overlapping, touching, or at most `gap` apart on both axes.
        func isNear(_ other: TileRect, gap: Int) -> Bool {
            x <= other.maxX + gap && other.x <= maxX + gap && y <= other.maxY + gap && other.y <= maxY + gap
        }
    }

    /// Changed cells as a row-major grid of `columns` x `rows`.
    struct CellGrid: Equatable, Sendable {
        var columns: Int
        var rows: Int
        var changed: [Bool]
        init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows; changed = Array(repeating: false, count: columns * rows) }
        subscript(column: Int, row: Int) -> Bool {
            get { changed[row * columns + column] }
            set { changed[row * columns + column] = newValue }
        }
        var isEmpty: Bool { !changed.contains(true) }
    }

    /// Compares two BGRA images of `width` x `height` pixels in square cells of `cellPixels`: a memcmp
    /// per row, and per cell only on rows that differ; a cell changed if a channel moved by more than
    /// `tolerance` levels.
    static func changedCells(current: UnsafeRawPointer, currentBytesPerRow: Int, previous: UnsafeRawPointer, previousBytesPerRow: Int,
                             width: Int, height: Int, cellPixels: Int, tolerance: UInt8 = 0) -> CellGrid {
        var grid = CellGrid(columns: (width + cellPixels - 1) / cellPixels, rows: (height + cellPixels - 1) / cellPixels)
        for y in 0..<height {
            let new = current + y * currentBytesPerRow, old = previous + y * previousBytesPerRow
            if memcmp(new, old, width * 4) == 0 { continue }
            let row = y / cellPixels
            for column in 0..<grid.columns where !grid[column, row] {
                let from = column * cellPixels, to = min(width, from + cellPixels)
                if differs(new + from * 4, old + from * 4, count: (to - from) * 4, tolerance: tolerance) { grid[column, row] = true }
            }
        }
        return grid
    }

    @inline(__always)
    private static func differs(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, count: Int, tolerance: UInt8) -> Bool {
        if memcmp(a, b, count) == 0 { return false }
        if tolerance == 0 { return true }
        let limit = SIMD16<UInt8>(repeating: tolerance)
        var offset = 0
        while offset + 16 <= count {
            let x = a.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            let y = b.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
            if any(pointwiseMax(x, y) &- pointwiseMin(x, y) .> limit) { return true }
            offset += 16
        }
        while offset < count {
            let x = a.load(fromByteOffset: offset, as: UInt8.self), y = b.load(fromByteOffset: offset, as: UInt8.self)
            if max(x, y) - min(x, y) > tolerance { return true }
            offset += 1
        }
        return false
    }

    /// Changed cells → merged tiles in points (connected cells first, then rects within `mergeGap`).
    static func tiles(for grid: CellGrid, pointWidth: Int, pointHeight: Int, cellSize: Int = cellSize, gap: Int = mergeGap) -> [TileRect] {
        var seen = Array(repeating: false, count: grid.changed.count)
        var rects: [TileRect] = []
        for start in grid.changed.indices where grid.changed[start] && !seen[start] {
            // Flood fill (8-connected) to the component's bounding box in cells.
            var stack = [start]
            seen[start] = true
            var minC = Int.max, minR = Int.max, maxC = Int.min, maxR = Int.min
            while let index = stack.popLast() {
                let c = index % grid.columns, r = index / grid.columns
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for dr in -1...1 { for dc in -1...1 {
                    let nc = c + dc, nr = r + dr
                    guard nc >= 0, nr >= 0, nc < grid.columns, nr < grid.rows else { continue }
                    let next = nr * grid.columns + nc
                    if grid.changed[next] && !seen[next] { seen[next] = true; stack.append(next) }
                } }
            }
            let x = minC * cellSize, y = minR * cellSize
            rects.append(TileRect(x: x, y: y, w: min(pointWidth, (maxC + 1) * cellSize) - x, h: min(pointHeight, (maxR + 1) * cellSize) - y))
        }
        return merge(rects, gap: gap)
    }

    /// Unions rects that overlap or lie within `gap` points of each other, until none do.
    static func merge(_ rects: [TileRect], gap: Int = mergeGap) -> [TileRect] {
        var rects = rects
        var merged = true
        while merged {
            merged = false
            outer: for i in rects.indices {
                for j in rects.indices where j > i && rects[i].isNear(rects[j], gap: gap) {
                    rects[i] = rects[i].union(rects[j])
                    rects.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return rects.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    // MARK: Encoding

    /// Encodes a BGRA (premultiplied, sRGB) region as JPEG or WebP, transparent pixels over `background`.
    static func encode(pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, background: CGColor,
                       format: MirrorProtocol.TileFormat, quality: Double = jpegQuality) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let destinationBase = context.data else { return nil }
        // Copy the region in, then paint the background behind it (destination-over).
        let destinationBytesPerRow = context.bytesPerRow
        for row in 0..<height {
            destinationBase.advanced(by: row * destinationBytesPerRow).copyMemory(from: pixels + row * bytesPerRow, byteCount: width * 4)
        }
        context.setBlendMode(.destinationOver)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }

        let data = NSMutableData()
        let type = format == .webp ? "org.webmproject.webp" : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Receives SCStream samples on the capture queue and forwards them to its `WindowCapture`.
private final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    weak var owner: WindowCapture?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        owner?.receive(sampleBuffer)
    }

    /// The window closed or capture was revoked.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owner?.finish()
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
