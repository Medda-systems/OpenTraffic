import AppKit
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import OpenTrafficCore

// Sharing an iPhone app from the iOS Simulator. Everything here runs on stubs (no simctl, no
// Simulator.app, no window server): the device's screen from its device type, finding the device's
// window, where the screen is in it, the input routing (touches, drags, keys), the narrowed
// accessibility, and whole sessions on a stub environment. The last suite drives a real simulator and
// skips unless OPENTRAFFIC_TEST_SIMULATOR_APP names one (see docs in its comment).

private typealias Proto = MirrorProtocol

// MARK: - Fixtures

/// The iPhone 17's capabilities.plist as Xcode 27 installs it (only the keys OpenTraffic reads),
/// recorded from /Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17.simdevicetype.
private nonisolated(unsafe) let iPhone17Capabilities: [String: Any] = [
    "capabilities": [
        "DeviceCornerRadius": 62,
        "ScreenDimensionsCapability": ["main-screen-height": 2622, "main-screen-scale": 3, "main-screen-width": 1206],
        "displays": [
            ["cornerRadiusUL": 62, "deviceName": "primary", "height": 2622, "scale": 3, "screenID": 1, "width": 1206],
            ["deviceName": "external-0", "height": 480, "scale": 1, "screenID": 2, "width": 720],
        ],
    ] as [String: Any],
]

private let iPhone17Screen = SimulatorScreen(points: CGSize(width: 402, height: 874), scale: 3, cornerRadius: 62)

/// The Simulator's device window as the stubs have it: 470 × 1000 points at (100, 50), a title bar and
/// the device bezel around a 402 × 874 screen at (34, 90).
private let deviceWindowID: UInt32 = 7001
private let otherWindowID: UInt32 = 7002
private let deviceFrame = CGRect(x: 100, y: 50, width: 470, height: 1000)
private let screenRect = CGRect(x: 34, y: 90, width: 402, height: 874)

private func window(_ number: UInt32?, _ title: String, frame: CGRect = deviceFrame, minimized: Bool = false, main: Bool = false) -> AccessibilityTree.Window {
    AccessibilityTree.Window(number: number, title: title, role: "AXWindow", subrole: "AXStandardWindow", frame: frame,
                             isMain: main, isFocused: main, isMinimized: minimized)
}

/// The device window's tree: the Simulator's toolbar buttons, its screen view, and the app's elements on it.
private func deviceNodes() -> [Proto.AXNode] {
    [
        Proto.AXNode(key: "/Window:", role: "AXWindow", label: "iPhone 17", x: 0, y: 0, w: 470, h: 1000, depth: 0),
        Proto.AXNode(key: "/Window:/AXToolbar:", role: "AXToolbar", x: 0, y: 0, w: 470, h: 52, depth: 1),
        Proto.AXNode(key: "/Window:/AXToolbar:/AXButton:Home", role: "AXButton", label: "Home", x: 380, y: 12, w: 28, h: 28, depth: 2, actions: [.press]),
        Proto.AXNode(key: "/Window:/AXGroup:", role: "AXGroup", x: 34, y: 90, w: 402, h: 874, depth: 1),
        Proto.AXNode(key: "/Window:/AXGroup:/AXButton:Add", role: "AXButton", label: "Add", x: 60, y: 150, w: 80, h: 44, depth: 2, actions: [.press]),
        Proto.AXNode(key: "/Window:/AXGroup:/AXTextField:Name", role: "AXTextField", label: "Name", value: "", x: 60, y: 220, w: 300, h: 36, depth: 2),
    ]
}

// MARK: - Stubs

/// Simulator.app's accessibility: two device windows (another booted device's, and this one's).
private final class StubSimulatorAccessibility: MirrorAccessibility, @unchecked Sendable {
    struct State {
        var windows: [AccessibilityTree.Window] = [
            window(otherWindowID, "iPhone 17 Pro", frame: CGRect(x: 700, y: 50, width: 470, height: 1000), main: true),
            window(deviceWindowID, "iPhone 17"),
        ]
        var nodes = deviceNodes()
        var refused: Set<String> = []
        var performed: [String] = []
        var raised: [UInt32] = []
        var resized = 0
        var closed = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func windows() async throws -> [AccessibilityTree.Window] { state.withLock { $0.windows } }

    func snapshot(window: AccessibilityTree.WindowSelector) async throws -> AXSnapshot {
        try state.withLock { state in
            guard case .number(let id) = window, let match = state.windows.first(where: { $0.number == id }) else { throw AccessibilityTreeError.noWindow }
            return AXSnapshot(windowNumber: id, title: match.title, frame: match.frame, nodes: id == deviceWindowID ? state.nodes : [state.nodes[0]],
                              surfaces: [AXSnapshot.Surface(number: 9, key: "/Window:/AXSheet:", role: "AXSheet", frame: .init(x: 0, y: 0, width: 300, height: 200))])
        }
    }

    func perform(key: String, action: Proto.Action, window: UInt32?) async throws {
        let refused = state.withLock { state -> Bool in
            state.performed.append(key)
            return state.refused.contains(key)
        }
        if refused { throw AccessibilityTreeError.axFailure(operation: "AXPress", code: -25204) }
    }

    func changes() -> AsyncStream<AXChange> { AsyncStream { _ in } }
    func raise(window: UInt32) async throws { state.withLock { $0.raised.append(window) } }
    func close(window: UInt32) async throws { state.withLock { $0.closed += 1 } }
    func resize(window: UInt32, to size: CGSize) async throws -> CGSize? { state.withLock { $0.resized += 1 }; return size }
}

/// Records what reaches Simulator.app.
private final class StubSimulatorInput: SimulatorInputDevice, @unchecked Sendable {
    let log = OSAllocatedUnfairLock(initialState: [String]())
    var events: [String] { log.withLock { $0 } }
    func clear() { log.withLock { $0.removeAll() } }

    func send(_ pointer: Proto.Pointer, in window: InputSynthesizer.Window) throws {
        log.withLock { $0.append("\(pointer.kind.rawValue) \(Int(pointer.x)),\(Int(pointer.y)) w\(window.id)") }
    }
    func dragged(to point: CGPoint, in window: InputSynthesizer.Window, modifiers: [Proto.Modifier]) throws {
        log.withLock { $0.append("drag \(Int(point.x)),\(Int(point.y)) w\(window.id)") }
    }
    func type(text: String) throws { log.withLock { $0.append("unicode \(text)") } }
    func send(_ key: Proto.Key) throws { log.withLock { $0.append("key \(key.code.rawValue)") } }
    func press(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        let name = String(format: "vk 0x%02X", virtualKey) + (flags.contains(.maskShift) ? " shift" : "") + (flags.contains(.maskCommand) ? " cmd" : "")
        log.withLock { $0.append(name) }
    }
    func replaceText(in window: InputSynthesizer.Window, field: CGRect, with text: String, timeout: Duration) async throws {
        log.withLock { $0.append("ax-replace \(text)") }
    }
}

private final class StubCapture: MirrorCapture, @unchecked Sendable {
    let windowID: CGWindowID
    let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let started = OSAllocatedUnfairLock(initialState: false)

    init(windowID: CGWindowID) {
        self.windowID = windowID
        (frames, continuation) = AsyncStream.makeStream(of: CapturedFrame.self)
    }

    func start() async throws {
        started.withLock { $0 = true }
        continuation.yield(frame())
    }
    func stop() async { continuation.finish() }
    func fullFrame() async -> CapturedFrame? { started.withLock { $0 } ? frame() : nil }

    private func frame() -> CapturedFrame {
        let tile = Proto.Tile(window: windowID, seq: 0, x: 0, y: 0, w: 470, h: 1000, format: .jpeg, data: grayJPEG(width: 47, height: 100))
        return CapturedFrame(window: windowID, seq: 0, full: true, width: 470, height: 1000, scale: 2, tiles: [tile], encodeTime: .zero)
    }
}

private func grayJPEG(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

// MARK: - The device's screen and window

@Suite("Simulator device screen and window")
struct SimulatorScreenTests {
    @Test func theScreenComesFromTheDeviceTypesCapabilities() {
        #expect(SimulatorScreen.parse(capabilities: iPhone17Capabilities) == iPhone17Screen)
        // Without ScreenDimensionsCapability, the primary display.
        var older = iPhone17Capabilities["capabilities"] as! [String: Any]
        older.removeValue(forKey: "ScreenDimensionsCapability")
        older.removeValue(forKey: "DeviceCornerRadius")
        #expect(SimulatorScreen.parse(capabilities: ["capabilities": older]) == iPhone17Screen)
        #expect(SimulatorScreen.parse(capabilities: ["capabilities": ["DeviceCornerRadius": 62]]) == nil)
    }

    @Test func aDeviceTypeIsFoundByItsIdentifierInTheProfileFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simdevicetypes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, identifier, capabilities) in [("iPhone 17 Pro", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", [String: Any]()),
                                                 ("iPhone 17", "com.apple.CoreSimulator.SimDeviceType.iPhone-17", iPhone17Capabilities)] {
            let contents = folder.appendingPathComponent("\(name).simdevicetype/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            #expect(NSDictionary(dictionary: ["CFBundleIdentifier": identifier, "CFBundleName": name]).write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
            #expect(NSDictionary(dictionary: capabilities).write(to: contents.appendingPathComponent("Resources/capabilities.plist"), atomically: true))
        }
        #expect(SimulatorScreen.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", folders: [folder]) == iPhone17Screen)
        #expect(SimulatorScreen.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", folders: [folder]) == nil)
        #expect(SimulatorScreen.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-Air", folders: [folder]) == nil)
    }

    @Test func theDevicesWindowIsFoundByItsName() {
        #expect(SimulatorWindows.title("iPhone 17", isDevice: "iPhone 17"))
        #expect(SimulatorWindows.title("iPhone 17 – iOS 26.0", isDevice: "iPhone 17"))
        #expect(SimulatorWindows.title("iPhone 17 - 26.0", isDevice: "iPhone 17"))
        #expect(!SimulatorWindows.title("iPhone 17 Pro", isDevice: "iPhone 17"))
        #expect(!SimulatorWindows.title("iPhone 17e", isDevice: "iPhone 17"))
        #expect(!SimulatorWindows.title("OpenTraffic · iPhone 17", isDevice: "iPhone 17"))
        #expect(SimulatorWindows.title("OpenTraffic · iPhone 17", isDevice: "OpenTraffic · iPhone 17"))
        #expect(!SimulatorWindows.title("iPhone 17", isDevice: ""))

        let windows = [
            window(1, "iPhone 17 Pro", main: true),
            window(2, "iPhone 17 – iOS 26.0"),
            window(3, "iPhone 17"),
            window(4, "OpenTraffic · iPhone 17"),
            window(nil, "iPhone 17e"),
            window(5, "iPhone 17e", minimized: true),
        ]
        #expect(SimulatorWindows.deviceWindow(windows, device: "iPhone 17")?.number == 3) // the exact title first
        #expect(SimulatorWindows.deviceWindow(Array(windows.prefix(2)), device: "iPhone 17")?.number == 2)
        #expect(SimulatorWindows.deviceWindow(windows, device: "OpenTraffic · iPhone 17")?.number == 4)
        #expect(SimulatorWindows.deviceWindow(windows, device: "iPhone 17e") == nil) // no number, minimized
        #expect(SimulatorWindows.deviceWindow(windows, device: "iPad Air") == nil)
    }

    @Test func theScreenIsTheElementWithItsProportions() throws {
        let mapping = try #require(SimulatorScreenMapping.locate(nodes: deviceNodes(), window: deviceFrame.size, screen: iPhone17Screen))
        #expect(mapping.rect == screenRect)
        #expect(mapping.factor == 1)
        // The Simulator showing the device at half its size: device points scale.
        var half = deviceNodes()
        half[3] = Proto.AXNode(key: "/Window:/AXGroup:", role: "AXGroup", x: 20, y: 60, w: 201, h: 437, depth: 1)
        let small = try #require(SimulatorScreenMapping.locate(nodes: half, window: CGSize(width: 241, height: 520), screen: iPhone17Screen))
        #expect(small.rect == CGRect(x: 20, y: 60, width: 201, height: 437))
        #expect(small.factor == 0.5)
        #expect(small.window(CGPoint(x: 100, y: 200)) == CGPoint(x: 70, y: 160))
        #expect(small.device(CGPoint(x: 70, y: 160)) == CGPoint(x: 100, y: 200))
        #expect(small.clamp(CGPoint(x: -50, y: 900)) == CGPoint(x: 21, y: 496))
        // The largest match wins over a smaller element of the same shape (a thumbnail in the app).
        var nested = deviceNodes()
        nested.append(Proto.AXNode(key: "/Window:/AXGroup:/AXImage:", role: "AXImage", x: 100, y: 300, w: 92, h: 200, depth: 2))
        #expect(SimulatorScreenMapping.locate(nodes: nested, window: deviceFrame.size, screen: iPhone17Screen)?.rect == screenRect)
    }

    @Test func withoutSuchAnElementTheScreenIsUnderTheTitleBarOrNotFound() {
        let windowOnly = [deviceNodes()[0]]
        // The Simulator without bezels: a 28-point title bar over the screen.
        let bare = SimulatorScreenMapping.locate(nodes: windowOnly, window: CGSize(width: 402, height: 902), screen: iPhone17Screen)
        #expect(bare?.rect == CGRect(x: 0, y: 28, width: 402, height: 874))
        // A bezel around it, and no element to say where: nothing (the viewer shows the whole window).
        #expect(SimulatorScreenMapping.locate(nodes: windowOnly, window: deviceFrame.size, screen: iPhone17Screen) == nil)
        // An unknown device type.
        #expect(SimulatorScreenMapping.locate(nodes: deviceNodes(), window: deviceFrame.size, screen: nil) == nil)
    }

    @Test func theViewerIsToldWhereTheScreenIsWithItsCornerRadius() {
        let mapping = SimulatorScreenMapping(rect: CGRect(x: 20, y: 60, width: 201, height: 437), points: iPhone17Screen.points)
        let device = mapping.device(named: "iPhone 17", cornerRadius: 62)
        #expect(device == Proto.Device(name: "iPhone 17", screen: .init(x: 20, y: 60, w: 201, h: 437, radius: 31)))
        // In hello, as the viewer reads it; a Mac app's hello has no device.
        let hello = Proto.ServerMessage.hello(.init(boot: "b", scale: 2, appearance: .light, app: .init(name: "Orbit", device: device), windows: []))
        let text = (try? hello.jsonString()) ?? ""
        #expect(text.contains(#""device":{"#) && text.contains(#""radius":31"#))
        #expect((try? Proto.ServerMessage.decode(text)) == hello)
        let mac = (try? Proto.ServerMessage.hello(.init(boot: "b", scale: 2, appearance: .light, app: .init(name: "Orbit"), windows: [])).jsonString()) ?? ""
        #expect(!mac.contains("device"))
    }
}

// MARK: - Accessibility

@Suite("Simulator accessibility narrowed to the device")
struct SimulatorAccessibilityTests {
    private func make(screen: SimulatorScreen? = iPhone17Screen) -> (SimulatorAccessibility, StubSimulatorAccessibility, OSAllocatedUnfairLock<[String]>) {
        let inner = StubSimulatorAccessibility()
        let taps = OSAllocatedUnfairLock(initialState: [String]())
        let narrowed = SimulatorAccessibility(inner: inner, deviceName: "iPhone 17", screen: screen) { number, frame, point in
            taps.withLock { $0.append("tap \(Int(point.x)),\(Int(point.y)) w\(number) at \(Int(frame.minX)),\(Int(frame.minY))") }
        }
        return (narrowed, inner, taps)
    }

    @Test func onlyTheDevicesWindowIsListedAsTheMainFocusedWindow() async throws {
        let (narrowed, inner, _) = make()
        let windows = try await narrowed.windows()
        #expect(windows.map(\.number) == [deviceWindowID])
        #expect(windows[0].isMain && windows[0].isFocused)
        // The mirror takes it as its main window.
        #expect(MirrorServer.mirroredWindows(windows, current: nil).map(\.info.kind) == [.main])
        inner.state.withLock { $0.windows.removeLast() }
        #expect(try await narrowed.windows().isEmpty)
    }

    @Test func snapshotsKeepTheScreensElementsOnly() async throws {
        let (narrowed, _, _) = make()
        let snapshot = try await narrowed.snapshot(window: .number(deviceWindowID))
        #expect(snapshot.nodes.map(\.key) == ["/Window:", "/Window:/AXGroup:", "/Window:/AXGroup:/AXButton:Add", "/Window:/AXGroup:/AXTextField:Name"])
        #expect(snapshot.surfaces.isEmpty)
        #expect(snapshot.frame == deviceFrame)
        #expect(narrowed.mapping(window: deviceWindowID)?.rect == screenRect)
        // `.main` is the device's window, not the Simulator's main window (another device).
        #expect(try await narrowed.snapshot(window: .main).windowNumber == deviceWindowID)
        // An unknown device type: everything stays (nothing says where the screen is).
        let (plain, _, _) = make(screen: nil)
        #expect(try await plain.snapshot(window: .number(deviceWindowID)).nodes.count == deviceNodes().count)
    }

    @Test func aPressTheBridgeRefusesBecomesATapAtTheElementsCentre() async throws {
        let (narrowed, inner, taps) = make()
        _ = try await narrowed.snapshot(window: .number(deviceWindowID))
        try await narrowed.perform(key: "/Window:/AXGroup:/AXButton:Add", action: .press, window: deviceWindowID)
        #expect(taps.withLock { $0 }.isEmpty)
        inner.state.withLock { $0.refused = ["/Window:/AXGroup:/AXButton:Add", "/Window:/AXGroup:/AXTextField:Name"] }
        try await narrowed.perform(key: "/Window:/AXGroup:/AXButton:Add", action: .press, window: deviceWindowID)
        #expect(taps.withLock { $0 } == ["tap 100,172 w7001 at 100,50"])
        // Other actions, and keys that aren't in the snapshot, fail as they did.
        await #expect(throws: AccessibilityTreeError.self) {
            try await narrowed.perform(key: "/Window:/AXGroup:/AXTextField:Name", action: .confirm, window: deviceWindowID)
        }
        inner.state.withLock { $0.refused.insert("/Window:/Gone") }
        await #expect(throws: AccessibilityTreeError.self) {
            try await narrowed.perform(key: "/Window:/Gone", action: .press, window: deviceWindowID)
        }
    }

    @Test func theWindowIsNeverResizedOrClosedButCanBeRaised() async throws {
        let (narrowed, inner, _) = make()
        #expect(try await narrowed.resize(window: deviceWindowID, to: CGSize(width: 800, height: 600)) == nil)
        try await narrowed.close(window: deviceWindowID)
        try await narrowed.raise(window: deviceWindowID)
        let state = inner.state.withLock { $0 }
        #expect(state.resized == 0 && state.closed == 0 && state.raised == [deviceWindowID])
    }
}

// MARK: - Input

@Suite("Simulator input routing")
struct SimulatorInputTests {
    private let target = InputSynthesizer.Window(id: deviceWindowID, frame: deviceFrame)
    private let mapping = SimulatorScreenMapping(rect: screenRect, points: iPhone17Screen.points)

    private func make(scrollEnd: Duration = .seconds(30)) -> (SimulatorInput, StubSimulatorInput, OSAllocatedUnfairLock<[String]>) {
        let device = StubSimulatorInput()
        let pasted = OSAllocatedUnfairLock(initialState: [String]())
        let mapping = mapping
        let input = SimulatorInput(inner: device, mapping: { $0 == deviceWindowID ? mapping : nil },
                                   paste: { text in pasted.withLock { $0.append(text) } }, scrollEnd: scrollEnd, focusDelay: .milliseconds(1))
        return (input, device, pasted)
    }

    private func pointer(_ kind: Proto.PointerKind, _ x: Double, _ y: Double, dx: Double = 0, dy: Double = 0) -> Proto.Pointer {
        Proto.Pointer(window: deviceWindowID, kind: kind, x: x, y: y, dx: dx, dy: dy)
    }

    @Test func clicksAreTouchesAndMovesWithTheButtonDownAreFingerMoves() throws {
        let (input, device, _) = make()
        try input.send(pointer(.move, 100, 200), in: target)
        try input.send(pointer(.down, 100, 200), in: target)
        try input.send(pointer(.move, 100, 300), in: target)
        try input.send(pointer(.up, 100, 300), in: target)
        try input.send(pointer(.move, 120, 300), in: target)
        // iOS has no right click.
        try input.send(pointer(.rightdown, 100, 200), in: target)
        try input.send(pointer(.rightup, 100, 200), in: target)
        #expect(device.events == ["move 100,200 w7001", "down 100,200 w7001", "drag 100,300 w7001", "up 100,300 w7001", "move 120,300 w7001"])
    }

    @Test func aWheelRunIsOneFingerDragThatLiftsWhenTheWheelStops() async throws {
        let (input, device, _) = make(scrollEnd: .milliseconds(40))
        // Scrolling down 30 + 50 points: the finger goes up.
        try input.send(pointer(.wheel, 200, 500, dy: 30), in: target)
        try input.send(pointer(.wheel, 210, 520, dy: 50), in: target)
        #expect(device.events == ["down 200,500 w7001", "drag 200,470 w7001", "drag 200,420 w7001"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(device.events.last == "up 200,420 w7001")
        #expect(device.events.count == 4)
        // A new run starts a new drag.
        device.clear()
        try input.send(pointer(.wheel, 200, 500, dx: -20, dy: -10), in: target)
        try await Task.sleep(for: .milliseconds(300))
        #expect(device.events == ["down 200,500 w7001", "drag 220,510 w7001", "up 220,510 w7001"])
    }

    @Test func otherInputLiftsTheFingerFirst() throws {
        let (input, device, _) = make()
        try input.send(pointer(.wheel, 200, 500, dy: 30), in: target)
        try input.send(pointer(.down, 100, 150), in: target)
        #expect(device.events == ["down 200,500 w7001", "drag 200,470 w7001", "up 200,470 w7001", "down 100,150 w7001"])
    }

    @Test func theFingerStaysOnTheScreenAndStartsAgainAtItsEdge() {
        var gesture = SimulatorScrollGesture()
        // Scrolling up 900 points from near the top: the finger would leave the screen at the bottom.
        let steps = gesture.wheel(at: CGPoint(x: 200, y: 100), dx: 0, dy: -900, window: deviceWindowID, screen: SimulatorScreenMapping(rect: screenRect, points: iPhone17Screen.points))
        #expect(steps == [.down(CGPoint(x: 200, y: 100)), .drag(CGPoint(x: 200, y: 963)), .up(CGPoint(x: 200, y: 963)), .down(CGPoint(x: 200, y: 100))])
        #expect(gesture.isActive)
        #expect(gesture.end() == [.up(CGPoint(x: 200, y: 100))])
        #expect(gesture.end().isEmpty)
        // Starting outside the screen (on the bezel): the finger goes down on the screen's edge.
        var outside = SimulatorScrollGesture()
        let first = outside.wheel(at: CGPoint(x: 10, y: 40), dx: 0, dy: 0, window: deviceWindowID, screen: SimulatorScreenMapping(rect: screenRect, points: iPhone17Screen.points))
        #expect(first.first == .down(CGPoint(x: 35, y: 91)))
    }

    @Test func textIsTypedKeyByKeyAndWhatNoKeyTypesIsPasted() throws {
        let (input, device, pasted) = make()
        try input.type(text: "Hi! a@b")
        #expect(device.events == ["vk 0x04 shift", "vk 0x22", "vk 0x12 shift", "vk 0x31", "vk 0x00", "vk 0x13 shift", "vk 0x0B"])
        device.clear()
        try input.type(text: "Café ok")
        #expect(device.events == ["vk 0x08 shift", "vk 0x00", "vk 0x03", "vk 0x09 cmd", "vk 0x31", "vk 0x1F", "vk 0x28"])
        #expect(pasted.withLock { $0 } == ["é"])
        device.clear()
        try input.send(Proto.Key(window: deviceWindowID, code: .enter))
        #expect(device.events == ["key Enter"])
    }

    @Test func setTextTapsTheFieldSelectsItsTextAndTypesOverIt() async throws {
        let (input, device, _) = make()
        try await input.replaceText(in: target, field: CGRect(x: 60, y: 220, width: 300, height: 36), with: "Bo", timeout: .seconds(1))
        #expect(device.events == ["down 210,238 w7001", "up 210,238 w7001", "vk 0x00 cmd", "vk 0x0B shift", "vk 0x1F"])
        device.clear()
        try await input.replaceText(in: target, field: CGRect(x: 60, y: 220, width: 300, height: 36), with: "", timeout: .seconds(1))
        #expect(device.events == ["down 210,238 w7001", "up 210,238 w7001", "vk 0x00 cmd", "key Backspace"])
    }

    @Test func theKeyTableCoversAUSKeyboard() {
        #expect(InputSynthesizer.keystroke(for: "a")! == (0x00, false))
        #expect(InputSynthesizer.keystroke(for: "Z")! == (0x06, true))
        #expect(InputSynthesizer.keystroke(for: "0")! == (0x1D, false))
        #expect(InputSynthesizer.keystroke(for: ")")! == (0x1D, true))
        #expect(InputSynthesizer.keystroke(for: "\n")! == (0x24, false))
        #expect(InputSynthesizer.keystroke(for: "\"")! == (0x27, true))
        #expect(InputSynthesizer.keystroke(for: "\\")! == (0x2A, false))
        #expect(InputSynthesizer.keystroke(for: "é") == nil)
        #expect(InputSynthesizer.keystroke(for: "Ä") == nil)
        #expect(InputSynthesizer.keystroke(for: "😀") == nil)
        // Every printable ASCII character has a key.
        for scalar in 0x20...0x7E {
            let character = Character(UnicodeScalar(UInt8(scalar)))
            #expect(InputSynthesizer.keystroke(for: character) != nil, "\(character)")
        }
    }
}

// MARK: - Whole sessions on a stub environment

/// Records what a session asks of the outside world, and answers like simctl and the Simulator would.
private final class StubWorld: @unchecked Sendable {
    struct State {
        var calls: [String] = []
        var apps: [Process] = []
        var simulatorRunning = true
        var windowShows = true
        var deviceAppearance: Proto.Appearance? = .dark
        var refusePermissions = false
        var outputs: [URL] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let accessibility = StubSimulatorAccessibility()
    let input = StubSimulatorInput()
    /// Stands in for Simulator.app: a process that is alive (this one).
    let simulatorPID = ProcessInfo.processInfo.processIdentifier

    var calls: [String] { state.withLock { $0.calls } }
    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    /// The app's process: a `sleep` this test starts (and kills to make the app "crash").
    func startApp() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        state.withLock { $0.apps.append(process) }
        return process.processIdentifier
    }

    var lastApp: Process? { state.withLock { $0.apps.last } }

    func cleanUp() {
        for process in state.withLock({ $0.apps }) where process.isRunning { process.terminate() }
    }

    func environment(windowTimeout: Duration = .seconds(5)) -> SimulatorEnvironment {
        SimulatorEnvironment(
            launch: { [self] app, data, output in
                record("launch \(data.rawValue)")
                if let output { state.withLock { $0.outputs.append(output) } }
                let device = data == .empty
                    ? SimulatorDevice(udid: "OWN-UDID", name: "iPhone 17", runtimeIdentifier: app.simulator!.runtimeIdentifier, deviceTypeIdentifier: app.simulator!.deviceTypeIdentifier)
                    : app.simulator!
                return SimulatorLaunch(device: device, bundleIdentifier: app.bundleIdentifier!, pid: try startApp(), usesRealData: data == .copy)
            },
            relaunch: { [self] launch, _ in
                record("relaunch \(launch.device.udid)")
                var again = launch
                again.pid = try startApp()
                return again
            },
            terminate: { [self] launch in
                record("terminate \(launch.device.udid)")
                if let app = lastApp, app.isRunning { app.terminate() }
            },
            stop: { [self] launch in
                record("stop \(launch.device.udid) \(launch.usesRealData ? "real" : "own")")
                if let app = lastApp, app.isRunning { app.terminate() }
            },
            setAppearance: { [self] device, appearance in record("appearance \(device.udid) \(appearance.rawValue)") },
            appearance: { [self] _ in state.withLock { $0.deviceAppearance } },
            runningSimulator: { [self] in state.withLock { $0.simulatorRunning } ? simulatorPID : nil },
            openSimulator: { [self] _, device, _ in
                record("open Simulator \(device.udid)")
                state.withLock { $0.simulatorRunning = true }
                return simulatorPID
            },
            quitSimulator: { [self] _, pid in record("quit Simulator \(pid == simulatorPID)") },
            accessibility: { [self] pid in
                record("accessibility \(pid == simulatorPID)")
                if !state.withLock({ $0.windowShows }) { accessibility.state.withLock { $0.windows = [] } }
                return accessibility
            },
            input: { [self] _ in input },
            capture: { StubCapture(windowID: $0) },
            paste: { [self] device, text in record("paste \(device.udid) \(text)") },
            screen: { _ in iPhone17Screen },
            checkPermissions: { [self] in
                if state.withLock({ $0.refusePermissions }) { throw MacAppSessionError.permission(.accessibility) }
            },
            windowTimeout: windowTimeout
        )
    }
}

private let simulatorDevice = SimulatorDevice(udid: "YOUR-UDID", name: "iPhone 17", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
                                              deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")

private let simulatorApp = MacApp(name: "Orbit", bundle: URL(fileURLWithPath: "/tmp/Orbit-iphonesimulator/Orbit.app"), bundleIdentifier: "se.medda.orbit",
                                  projectDirectory: nil, isRunning: true, runtime: .simulator(simulatorDevice))

private let assets = MirrorServer.Assets(page: Data("<!doctype html>".utf8), script: Data("//".utf8), style: Data("".utf8))

@MainActor
private func makeSession(_ world: StubWorld, data: MacAppSession.DataSource = .copy, appearance: MacAppViewerOptions.Appearance = .light,
                         windowTimeout: Duration = .seconds(5)) -> MacAppSession {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simulator-session-\(UUID().uuidString)", isDirectory: true)
    let options = MacAppSession.Options(app: simulatorApp, data: data, assets: assets, viewerOptions: .init(appearance: appearance),
                                        sessionDirectory: folder, windowTimeout: .seconds(5))
    return MacAppSession(options: options, simulator: world.environment(windowTimeout: windowTimeout))
}

@MainActor
private func waitFor(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// The first `hello` a viewer gets.
private func firstHello(port: Int) async throws -> Proto.Hello? {
    let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)\(Proto.webSocketPath)")!)
    task.maximumMessageSize = 64 << 20
    task.resume()
    defer { task.cancel(with: .goingAway, reason: nil) }
    for _ in 0..<20 {
        if case .string(let text) = try await task.receive(), case .hello(let hello)? = try? Proto.ServerMessage.decode(text) { return hello }
    }
    return nil
}

@Suite("Simulator share lifecycle on stubs", .serialized)
@MainActor
struct SimulatorShareLifecycleTests {
    @Test func aShareInYourRunningSimulatorServesTheDevicesWindowAndLeavesTheSimulatorRunning() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        let session = makeSession(world)
        let port = try await session.start()
        #expect(session.state == .running)
        #expect(session.pid == world.lastApp?.processIdentifier)
        #expect(world.calls == ["launch copy", "accessibility true"])
        // simctl writes the app's output to the session's log file.
        #expect(world.state.withLock { $0.outputs }.first?.path.hasPrefix(session.sessionDirectory.path) == true)
        // Your own simulator keeps its appearance (dark), whatever the host asked for.
        #expect(session.appearance == .dark)

        let hello = try #require(try await firstHello(port: port))
        #expect(hello.app.name == "Orbit")
        #expect(hello.app.device == Proto.Device(name: "iPhone 17", screen: .init(x: 34, y: 90, w: 402, h: 874, radius: 62)))
        #expect(hello.windows.map(\.id) == [deviceWindowID])
        #expect(hello.windows.first?.title == "iPhone 17")
        #expect(await session.mirroredWindows().map(\.kind) == [.main])

        await session.stop()
        #expect(session.state == .stopped)
        #expect(world.calls.suffix(2) == ["terminate YOUR-UDID", "stop YOUR-UDID real"])
        #expect(!world.calls.contains { $0.hasPrefix("quit Simulator") || $0.hasPrefix("open Simulator") })
        #expect(!FileManager.default.fileExists(atPath: session.sessionDirectory.path))
    }

    @Test func withoutARunningSimulatorItIsOpenedHiddenAndQuitAtTheEnd() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        world.state.withLock { $0.simulatorRunning = false }
        let session = makeSession(world, data: .empty, appearance: .dark)
        _ = try await session.start()
        // OpenTraffic's own device gets the host's appearance; the Simulator opens hidden on it.
        #expect(world.calls == ["launch empty", "appearance OWN-UDID dark", "open Simulator OWN-UDID", "accessibility true"])
        #expect(session.appearance == .dark)
        await session.stop()
        #expect(world.calls.suffix(3) == ["terminate OWN-UDID", "stop OWN-UDID own", "quit Simulator true"])
    }

    @Test func restartRelaunchesInTheSameDeviceAndResetErasesOpenTrafficsOwn() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        let session = makeSession(world, data: .empty)
        let port = try await session.start()
        let first = session.pid
        try await session.restart()
        #expect(session.state == .running)
        #expect(session.port == port)
        #expect(session.pid != first)
        #expect(world.calls.suffix(4) == ["terminate OWN-UDID", "relaunch OWN-UDID", "appearance OWN-UDID light", "accessibility true"])
        try await session.resetData()
        // Empty data again: the launcher erases the device and installs the app afresh.
        #expect(world.calls.suffix(4) == ["terminate OWN-UDID", "launch empty", "appearance OWN-UDID light", "accessibility true"])
        #expect(session.state == .running)
        await session.stop()
    }

    @Test func anAppThatQuitsIsStartedAgainInItsDevice() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        let session = makeSession(world)
        _ = try await session.start()
        let first = try #require(world.lastApp)
        first.terminate()
        #expect(await waitFor { world.calls.contains("relaunch YOUR-UDID") && session.state == .running })
        #expect(session.pid != first.processIdentifier)
        #expect(session.recentLog.contains { $0.text.contains("quit unexpectedly") })
        await session.stop()
    }

    @Test func viewerInputReachesTheSimulatorAsTouchesAndKeys() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        let session = makeSession(world)
        let port = try await session.start()
        // A viewer: its hello first, then a finger drag and some typing.
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)\(Proto.webSocketPath)")!)
        task.maximumMessageSize = 64 << 20
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        _ = try await task.receive()
        for message: Proto.ClientMessage in [
            .pointer(.init(window: deviceWindowID, kind: .down, x: 100, y: 172)),
            .pointer(.init(window: deviceWindowID, kind: .move, x: 100, y: 300)),
            .pointer(.init(window: deviceWindowID, kind: .up, x: 100, y: 300)),
            .text(.init(window: deviceWindowID, text: "ok")),
        ] {
            try await task.send(.string(try message.jsonString()))
        }
        #expect(await waitFor { world.input.events.count >= 5 })
        #expect(world.input.events == ["down 100,172 w7001", "drag 100,300 w7001", "up 100,300 w7001", "vk 0x1F", "vk 0x28"])
        await session.stop()
    }

    @Test func aDeviceWindowThatNeverShowsFailsTheStartAndCleansUp() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        world.state.withLock { $0.windowShows = false }
        let session = makeSession(world, windowTimeout: .milliseconds(300))
        await #expect(throws: MacAppSessionError.self) { try await session.start() }
        guard case .failed(let message) = session.state else { Issue.record("not failed: \(session.state)"); return }
        #expect(message.contains("didn't show iPhone 17"))
        #expect(world.calls.last == "stop YOUR-UDID real")
        #expect(world.lastApp?.isRunning == false)
    }

    @Test func missingPermissionsStopTheStartBeforeAnythingRuns() async throws {
        let world = StubWorld()
        defer { world.cleanUp() }
        world.state.withLock { $0.refusePermissions = true }
        let session = makeSession(world)
        await #expect(throws: MacAppSessionError.permission(.accessibility)) { try await session.start() }
        #expect(!world.calls.contains { $0.hasPrefix("launch") })
    }
}

// MARK: - A real simulator

/// Drives a real iPhone app in a booted simulator. Skips unless OPENTRAFFIC_TEST_SIMULATOR_APP is the
/// app's id as OpenTraffic lists it (`simulator:<udid>/<bundle id>`, see `opentraffic services`) and
/// this process has Accessibility and Screen Recording. Set OPENTRAFFIC_TEST_SIMULATOR_BUTTON to a
/// button's label to press it, and OPENTRAFFIC_TEST_SIMULATOR_FIELD to a text field's label to type in.
@Suite("Simulator share on a real simulator", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OPENTRAFFIC_TEST_SIMULATOR_APP"] != nil, "OPENTRAFFIC_TEST_SIMULATOR_APP isn't set"))
@MainActor
struct SimulatorShareLiveTests {
    @Test func theAppsElementsAreListedAButtonPressesAndAFieldTakesText() async throws {
        let environment = ProcessInfo.processInfo.environment
        let id = try #require(environment["OPENTRAFFIC_TEST_SIMULATOR_APP"])
        guard AccessibilityTree.isTrusted, WindowCapture.isPermitted else { return }
        let app = try SimulatorDiscovery.resolve(id: id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simulator-live-\(UUID().uuidString)", isDirectory: true)
        let session = MacAppSession(options: .init(app: app, data: .copy, assets: assets, sessionDirectory: folder, windowTimeout: .seconds(60)))
        let port = try await session.start()
        defer { Task { await session.stop() } }
        let hello = try #require(try await firstHello(port: port))
        #expect(hello.app.device?.screen != nil, "the device's screen wasn't found in the Simulator's window")
        let server = try #require(session.server)
        let windows = try await MirrorServer.readWindows(server.configuration.app.accessibility)
        let nodes = try #require(windows.first?.snapshot.nodes)
        #expect(nodes.count > 2, "Simulator.app showed no elements of the app")
        if let label = environment["OPENTRAFFIC_TEST_SIMULATOR_BUTTON"], let button = nodes.first(where: { $0.label == label }) {
            server.replay(.act(.init(window: hello.windows[0].id, key: button.key, action: .press)))
            try await Task.sleep(for: .seconds(1))
        }
        if let label = environment["OPENTRAFFIC_TEST_SIMULATOR_FIELD"], let field = nodes.first(where: { $0.label == label }) {
            server.replay(.setText(.init(window: hello.windows[0].id, key: field.key, value: "OpenTraffic")))
            try await Task.sleep(for: .seconds(2))
            let after = try await MirrorServer.readWindows(server.configuration.app.accessibility)
            #expect(after.first?.snapshot.nodes.first { $0.label == label }?.value == "OpenTraffic")
        }
    }
}
