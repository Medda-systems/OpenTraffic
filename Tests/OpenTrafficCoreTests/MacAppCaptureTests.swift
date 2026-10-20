import AppKit
import Foundation
import ImageIO
import os
import Testing
@testable import OpenTrafficCore

// Window capture: change detection, tile merging and encoding on synthetic pixels (no permissions
// needed), and live ScreenCaptureKit runs against a window the test creates below the desktop, so
// it is captured but never seen. The live tests skip without Screen Recording permission (GitHub
// Actions has none).

private typealias Rect = WindowCapture.TileRect

// MARK: Change detection and merging

@Test func mergingJoinsNearbyRectsAndKeepsDistantOnesApart() {
    let near = WindowCapture.merge([Rect(x: 0, y: 0, w: 16, h: 16), Rect(x: 24, y: 0, w: 16, h: 16)])
    #expect(near == [Rect(x: 0, y: 0, w: 40, h: 16)])

    let apart = WindowCapture.merge([Rect(x: 0, y: 0, w: 16, h: 16), Rect(x: 25, y: 0, w: 16, h: 16)])
    #expect(apart.count == 2)

    // A union can bring a third rect within reach: merging repeats until nothing is near.
    let chain = WindowCapture.merge([Rect(x: 0, y: 0, w: 16, h: 16), Rect(x: 100, y: 40, w: 16, h: 16), Rect(x: 20, y: 0, w: 80, h: 36)])
    #expect(chain == [Rect(x: 0, y: 0, w: 116, h: 56)])
}

@Test func changedCellsBecomeConnectedTilesClippedToTheWindow() {
    // A 100x50 point window in 16-point cells: 7 x 4 cells, the last column and row partial.
    var grid = WindowCapture.CellGrid(columns: 7, rows: 4)
    grid[0, 0] = true
    grid[1, 1] = true  // diagonal neighbour of (0,0): one tile
    grid[6, 3] = true  // the bottom-right cell, cut at 100x50
    let tiles = WindowCapture.tiles(for: grid, pointWidth: 100, pointHeight: 50)
    #expect(tiles == [Rect(x: 0, y: 0, w: 32, h: 32), Rect(x: 96, y: 48, w: 4, h: 2)])
    #expect(WindowCapture.tiles(for: WindowCapture.CellGrid(columns: 7, rows: 4), pointWidth: 100, pointHeight: 50).isEmpty)
}

@Test func onlyTheCellsWhosePixelsDifferAreChanged() {
    let width = 100, height = 70, bytesPerRow = width * 4
    let old = [UInt8](repeating: 0x80, count: bytesPerRow * height)
    var new = old
    new[5 * bytesPerRow + 37 * 4 + 2] = 0x81  // pixel (37, 5): cell (1, 0) with 32-pixel cells
    new[69 * bytesPerRow + 99 * 4] = 0        // pixel (99, 69): the last, partial cell (3, 2)
    let grid = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
        WindowCapture.changedCells(current: n.baseAddress!, currentBytesPerRow: bytesPerRow, previous: o.baseAddress!,
                                   previousBytesPerRow: bytesPerRow, width: width, height: height, cellPixels: 32)
    } }
    #expect(grid.columns == 4 && grid.rows == 3)
    #expect(grid.changed.indices.filter { grid.changed[$0] } == [1, 2 * 4 + 3])

    let same = old.withUnsafeBytes { o in
        WindowCapture.changedCells(current: o.baseAddress!, currentBytesPerRow: bytesPerRow, previous: o.baseAddress!,
                                   previousBytesPerRow: bytesPerRow, width: width, height: height, cellPixels: 32)
    }
    #expect(same.isEmpty)
}

@Test func differencesWithinTheToleranceAreNotChanges() {
    let width = 64, height = 32, bytesPerRow = width * 4
    let old = [UInt8](repeating: 0x80, count: bytesPerRow * height)
    var new = old.map { $0 &+ 1 }                  // every channel one level up: a re-render, not a change
    new[10 * bytesPerRow + 40 * 4 + 1] = 0x80 + 2  // pixel (40, 10): two levels, in cell (1, 0)
    let grid = old.withUnsafeBytes { o in new.withUnsafeBytes { n in
        WindowCapture.changedCells(current: n.baseAddress!, currentBytesPerRow: bytesPerRow, previous: o.baseAddress!,
                                   previousBytesPerRow: bytesPerRow, width: width, height: height, cellPixels: 32,
                                   tolerance: WindowCapture.tolerance)
    } }
    #expect(grid.changed == [false, true])
}

// MARK: Encoding

@Test func transparentPixelsAreEncodedOverTheBackground() throws {
    // 8x8 BGRA: left half fully transparent, right half opaque blue.
    var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
    for y in 0..<8 { for x in 4..<8 { pixels.replaceSubrange((y * 32 + x * 4)..<(y * 32 + x * 4 + 4), with: [255, 0, 0, 255]) } }
    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    let data = try #require(pixels.withUnsafeBytes {
        WindowCapture.encode(pixels: $0.baseAddress!, bytesPerRow: 32, width: 8, height: 8, background: red, format: .jpeg)
    })
    #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    let image = try decode(data)
    #expect(image.width == 8 && image.height == 8)
    #expect(isClose(try rgb(image, x: 1, y: 4), to: (255, 0, 0)))
    #expect(isClose(try rgb(image, x: 6, y: 4), to: (0, 0, 255)))
}

@Test func webPFallsBackToJPEGWhereItCannotBeEncoded() {
    let capture = WindowCapture(windowID: 1, format: .webp)
    #expect(capture.format == (WindowCapture.canEncodeWebP ? .webp : .jpeg))
    #expect(WindowCapture(windowID: 1, mirrorWindow: 7).mirrorWindow == 7)
}

// MARK: Live capture (Screen Recording permission)

// Each test takes a MacAppFixtureTurn (capture timing suffers when another Mac app test of this run
// runs at the same time, and ScreenCaptureKit stalls while another test process keeps a virtual
// display); the time limit allows for waiting for it.
@Suite(.serialized, .enabled(if: WindowCapture.isPermitted, "needs Screen Recording permission"), .macAppFixtureTurn, .timeLimit(.minutes(10)))
@MainActor
struct LiveWindowCaptureTests {
    @Test func theFirstFrameIsOneFullTileOfTheWindowsSize() async throws {
        let window = TestWindow()
        defer { window.close() }
        let capture = WindowCapture(windowID: window.id)
        let recorder = Recorder(capture)
        try await startRetryingOnce(capture)
        defer { Task { await capture.stop() } }

        let first = try #require(await recorder.frame(0, within: .seconds(5)))
        #expect(first.full && first.seq == 1 && first.width == 400 && first.height == 300)
        #expect(first.scale == Double(window.scale))
        let tile = try #require(first.tiles.first)
        #expect(first.tiles.count == 1 && tile.x == 0 && tile.y == 0 && tile.w == 400 && tile.h == 300)
        #expect(tile.window == window.id && tile.seq == first.seq && tile.format == capture.format)
        let image = try decode(tile.data)
        #expect(image.width == Int(400 * window.scale) && image.height == Int(300 * window.scale))
        #expect(first.header == MirrorProtocol.FrameHeader(window: window.id, seq: 1, full: true, tiles: 1))
        // The box (red, 40x40 at 20,20 from the top-left) is where the frame says.
        #expect(isClose(try rgb(image, x: Int(40 * window.scale), y: Int(40 * window.scale)), to: (255, 0, 0)))
        #expect(isClose(try rgb(image, x: Int(200 * window.scale), y: Int(150 * window.scale)), to: (255, 255, 255)))
    }

    @Test func nothingWhileIdleThenAChangeArrivesQuicklyAsASmallTile() async throws {
        let window = TestWindow()
        defer { window.close() }
        let capture = WindowCapture(windowID: window.id)
        let recorder = Recorder(capture)
        try await startRetryingOnce(capture)
        defer { Task { await capture.stop() } }
        _ = try #require(await recorder.frame(0, within: .seconds(5)))

        // Idle: SCStream keeps delivering frames, none with changed pixels.
        try await Task.sleep(for: .seconds(1))
        #expect(recorder.count == 1, "frames while idle: \(recorder.frames.dropFirst().map(\.frame.seq))")

        var latencies: [Duration] = []
        var stall = Duration.zero
        for (index, color) in [NSColor.blue, .green, .red, .orange, .purple].enumerated() {
            let changed = ContinuousClock.now
            window.paintBox(color)
            // ScreenCaptureKit now and then loses a change; WindowCapture recovers it within about 1.6 s.
            let entry = try #require(await recorder.entry(1 + index, within: .seconds(3)))
            latencies.append(entry.arrived - changed)
            let frame = entry.frame
            #expect(!frame.full)
            // The box is 40x40 points at (20,20): one tile covering it, far smaller than the window.
            let area = frame.tiles.reduce(0) { $0 + Int($1.w) * Int($1.h) }
            #expect(frame.tiles.count == 1 && area < 400 * 300 / 4)
            let tile = try #require(frame.tiles.first)
            #expect(tile.x <= 20 && tile.y <= 20 && Int(tile.x) + Int(tile.w) >= 60 && Int(tile.y) + Int(tile.h) >= 60)
            let image = try decode(tile.data)
            #expect(image.width == Int(Double(tile.w) * frame.scale))
            let slept = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(150))
            stall = max(stall, ContinuousClock.now - slept - .milliseconds(150))
        }
        // Every change arrived (above), and the fastest within 100 ms. Not every single one, and not
        // even that when the Mac is stalling (the test's own 150 ms sleeps overran by more than 30 ms):
        // on a loaded Mac everything pauses now and then, capture or not, so all latencies are printed.
        print("capture latency per change: \(latencies.map { String(format: "%.1f ms", $0.ms) }); longest sleep overrun \(String(format: "%.1f", stall.ms)) ms; encode: \(recorder.frames.map { String(format: "%.1f", $0.frame.encodeTime.ms) }) ms")
        if stall < .milliseconds(30) {
            #expect(latencies.min()! < .milliseconds(100), "latencies \(latencies)")
        }
        #expect(recorder.count == 6, "one frame per change, none in between")
    }

    @Test func roundedCornersAreFilledWithTheBackground() async throws {
        let window = TestWindow(cornerRadius: 24)
        defer { window.close() }
        let capture = WindowCapture(windowID: window.id, background: CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
        let recorder = Recorder(capture)
        try await startRetryingOnce(capture)
        defer { Task { await capture.stop() } }

        let first = try #require(await recorder.frame(0, within: .seconds(5)))
        let image = try decode(try #require(first.tiles.first).data)
        let corner = try rgb(image, x: 2, y: 2), farCorner = try rgb(image, x: image.width - 3, y: image.height - 3)
        #expect(isClose(corner, to: (0, 204, 0)), "top-left corner \(corner)")
        #expect(isClose(farCorner, to: (0, 204, 0)), "bottom-right corner \(farCorner)")
        #expect(isClose(try rgb(image, x: image.width / 2, y: image.height / 2), to: (255, 255, 255)))
    }

    @Test func aResizeSendsAFullFrameOfTheNewSize() async throws {
        let window = TestWindow()
        defer { window.close() }
        let capture = WindowCapture(windowID: window.id)
        let recorder = Recorder(capture)
        try await startRetryingOnce(capture)
        defer { Task { await capture.stop() } }
        _ = try #require(await recorder.frame(0, within: .seconds(5)))

        window.resize(to: NSSize(width: 500, height: 350))
        let resized = try #require(await recorder.first(within: .seconds(5)) { $0.width == 500 && $0.height == 350 })
        #expect(resized.full && resized.tiles.count == 1)
        let image = try decode(try #require(resized.tiles.first).data)
        #expect(image.width == Int(500 * window.scale) && image.height == Int(350 * window.scale))
        #expect(recorder.frames.allSatisfy { $0.frame.full || $0.frame.width == 500 }, "no frame scaled to the old size")
    }

    @Test func fullFrameOnRequestAndSnapshotShowTheCurrentPixels() async throws {
        let window = TestWindow()
        defer { window.close() }
        #expect(try await WindowCapture.snapshot(windowID: window.id).width == Int(400 * window.scale))

        let capture = WindowCapture(windowID: window.id)
        #expect(await capture.fullFrame() == nil)
        let recorder = Recorder(capture)
        try await startRetryingOnce(capture)
        defer { Task { await capture.stop() } }
        _ = try #require(await recorder.frame(0, within: .seconds(5)))
        window.paintBox(.blue)
        let change = try #require(await recorder.frame(1, within: .seconds(2)))

        let full = try #require(await capture.fullFrame())
        #expect(full.full && full.seq == change.seq && full.tiles.count == 1)
        let image = try decode(try #require(full.tiles.first).data)
        #expect(isClose(try rgb(image, x: Int(40 * window.scale), y: Int(40 * window.scale)), to: (0, 0, 255)))
        #expect(recorder.count == 2, "fullFrame() is not sent into frames")

        let snapshot = try await WindowCapture.snapshot(windowID: window.id)
        #expect(snapshot.width == Int(400 * window.scale) && snapshot.height == Int(300 * window.scale))
    }

    @Test func closingTheWindowFinishesTheStream() async throws {
        let window = TestWindow()
        let capture = WindowCapture(windowID: window.id)
        let recorder = Recorder(capture)
        try await startRetryingOnce(capture)
        _ = try #require(await recorder.frame(0, within: .seconds(5)))
        window.close()
        #expect(await recorder.waitUntilFinished(within: .seconds(5)))
        await capture.stop()
    }

    @Test func anUnknownWindowIsReported() async throws {
        await #expect(throws: WindowCaptureError.windowNotFound(0xFFFF_FFF0)) {
            try await WindowCapture(windowID: 0xFFFF_FFF0).start()
        }
        await #expect(throws: WindowCaptureError.windowNotFound(0xFFFF_FFF0)) {
            _ = try await WindowCapture.snapshot(windowID: 0xFFFF_FFF0)
        }
    }
}

// MARK: Helpers

/// replayd (ScreenCaptureKit's daemon) is started on demand, and its first answers after a start can
/// be a timeout or "declined" (-3801) although permission is granted: try once more.
private func startRetryingOnce(_ capture: WindowCapture) async throws {
    do {
        try await capture.start()
    } catch {
        guard (error as? WindowCaptureError) == .timedOut || (error as NSError).code == -3801 else { throw error }
        try await Task.sleep(for: .seconds(1))
        try await capture.start()
    }
}

/// A borderless 400x300 window ordered below the desktop: the window server renders it (so it can be
/// captured), nobody sees it. White, with a red 40x40 box at (20,20) from the top-left.
@MainActor
private final class TestWindow {
    let window: NSWindow
    private let box: NSView

    private static var launched = false

    init(cornerRadius: CGFloat = 0) {
        // The test runner never calls NSApplication.run(). Without finishLaunching() the window server
        // holds back some of this process's updates (a change reaches the screen a second later, or not
        // at all until the next one).
        if !Self.launched {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            Self.launched = true
        }
        // The primary display (NSScreen.main follows the key window, which may be on another display or
        // none): a window outside every display isn't rendered, so it could never be captured.
        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: screen.minX + 80, y: screen.minY + 80, width: 400, height: 300),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.layer?.cornerRadius = cornerRadius
        content.layer?.masksToBounds = cornerRadius > 0
        content.autoresizingMask = [.width, .height]
        box = NSView(frame: NSRect(x: 20, y: 20, width: 40, height: 40))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
        content.addSubview(box)
        window.contentView = content
        window.orderFrontRegardless()
        CATransaction.flush()
    }

    var id: CGWindowID { CGWindowID(window.windowNumber) }
    var scale: CGFloat { window.backingScaleFactor }

    /// An explicit transaction, committed now: the test runner has no AppKit run loop.
    func paintBox(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.layer?.backgroundColor = color.usingColorSpace(.sRGB)?.cgColor
        CATransaction.commit()
        CATransaction.flush()
    }

    func resize(to size: NSSize) {
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func close() {
        window.orderOut(nil)
        window.close()
        CATransaction.flush()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Collects a capture's frames with their arrival times.
private final class Recorder: Sendable {
    struct Entry: Sendable { let frame: CapturedFrame; let arrived: ContinuousClock.Instant }
    private let state = OSAllocatedUnfairLock(initialState: (entries: [Entry](), finished: false))

    init(_ capture: WindowCapture) {
        let frames = capture.frames
        Task.detached { [state] in
            for await frame in frames {
                let entry = Entry(frame: frame, arrived: .now)
                state.withLock { $0.entries.append(entry) }
            }
            state.withLock { $0.finished = true }
        }
    }

    var frames: [Entry] { state.withLock { $0.entries } }
    var count: Int { frames.count }

    func entry(_ index: Int, within timeout: Duration) async -> Entry? {
        await poll(timeout) { frames.count > index ? frames[index] : nil }
    }

    func frame(_ index: Int, within timeout: Duration) async -> CapturedFrame? { await entry(index, within: timeout)?.frame }

    func first(within timeout: Duration, where match: @escaping @Sendable (CapturedFrame) -> Bool) async -> CapturedFrame? {
        await poll(timeout) { frames.first { match($0.frame) }?.frame }
    }

    func waitUntilFinished(within timeout: Duration) async -> Bool {
        await poll(timeout) { state.withLock { $0.finished } ? true : nil } ?? false
    }

    private func poll<T>(_ timeout: Duration, _ check: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = check() { return value }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return check()
    }
}

private func decode(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// The sRGB color of one pixel (x, y from the top-left).
private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

/// JPEG is lossy: within 40 per channel.
private func isClose(_ color: (Int, Int, Int), to expected: (Int, Int, Int)) -> Bool {
    abs(color.0 - expected.0) <= 40 && abs(color.1 - expected.1) <= 40 && abs(color.2 - expected.2) <= 40
}

private extension Duration {
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
