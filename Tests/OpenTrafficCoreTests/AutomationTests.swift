import Foundation
import Testing
@testable import OpenTrafficCore

private func parse(_ string: String) -> AutomationCommand? {
    AutomationCommand.parse(URL(string: string)!)
}

@Test func parsesShareCommands() {
    #expect(parse("opentraffic://share?port=3000") == .share(localURL: "http://localhost:3000", kind: .quick, name: nil))
    #expect(parse("opentraffic://share?port=5173&via=tailscale&name=Docs") == .share(localURL: "http://localhost:5173", kind: .tailscale, name: "Docs"))
    #expect(parse("opentraffic://share?url=https://127.0.0.1:8443&via=ngrok") == .share(localURL: "https://127.0.0.1:8443", kind: .ngrok, name: nil))
    #expect(parse("opentraffic://share?port=70000") == nil)
    #expect(parse("opentraffic://share?url=file:///etc/passwd") == nil)
    #expect(parse("opentraffic://share?port=3000&via=carrier-pigeon") == nil)
}

@Test func parsesControlCommands() {
    #expect(parse("opentraffic://start?name=Landing") == .start(name: "Landing"))
    #expect(parse("opentraffic://stop?name=Landing") == .stop(name: "Landing"))
    #expect(parse("opentraffic://stop?all") == .stopAll)
    #expect(parse("opentraffic://copy?name=Docs%20Site") == .copy(name: "Docs Site"))
    #expect(parse("opentraffic://show") == .show(name: nil))
    #expect(parse("opentraffic://project?name=Shop&action=start") == .startProject("Shop"))
    #expect(parse("opentraffic://project?name=Shop&action=stop") == .stopProject("Shop"))
    #expect(parse("opentraffic://start") == nil)
    #expect(parse("https://share?port=3000") == nil)
}

@Test func onlyExposingCommandsNeedConfirmation() {
    #expect(AutomationCommand.share(localURL: "http://localhost:1", kind: .quick, name: nil).exposesService)
    #expect(AutomationCommand.start(name: "x").exposesService)
    #expect(AutomationCommand.startProject("x").exposesService)
    #expect(!AutomationCommand.stop(name: "x").exposesService)
    #expect(!AutomationCommand.stopAll.exposesService)
    #expect(!AutomationCommand.copy(name: "x").exposesService)
}

@Test func restartPolicyBacksOffAndGivesUp() {
    let policy = RestartPolicy()
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(policy.nextDelay(previousRestarts: [], now: now) == 2)
    #expect(policy.nextDelay(previousRestarts: [now.addingTimeInterval(-5)], now: now) == 10)
    #expect(policy.nextDelay(previousRestarts: [now.addingTimeInterval(-50), now.addingTimeInterval(-5)], now: now) == 30)
    #expect(policy.nextDelay(previousRestarts: [now, now, now], now: now) == nil)
    // Old restarts fall out of the window.
    #expect(policy.nextDelay(previousRestarts: [now.addingTimeInterval(-3600), now.addingTimeInterval(-3000), now.addingTimeInterval(-2000)], now: now) == 2)
}

@Test func autoStartWaitsForServiceAndRespectsManualStop() {
    var tracker = AutoStartTracker()
    let id = UUID()
    let whileDown = tracker.observe(id, serviceReachable: false, tunnelActive: false)
    let whenUp = tracker.observe(id, serviceReachable: true, tunnelActive: false)
    let whileRunning = tracker.observe(id, serviceReachable: true, tunnelActive: true)
    tracker.userStopped(id)
    let afterManualStop = tracker.observe(id, serviceReachable: true, tunnelActive: false)
    // Server restarts: down, then up again → start.
    let serverDown = tracker.observe(id, serviceReachable: false, tunnelActive: false)
    let serverBack = tracker.observe(id, serviceReachable: true, tunnelActive: false)
    #expect(!whileDown)
    #expect(whenUp)
    #expect(!whileRunning)
    #expect(!afterManualStop)
    #expect(!serverDown)
    #expect(serverBack)
}

@Test func autoStartDoesNotRetryAFailedStartUntilTheServiceComesBack() {
    var tracker = AutoStartTracker()
    let id = UUID()
    let first = tracker.observe(id, serviceReachable: true, tunnelActive: false)
    // The start failed: the tunnel is inactive again but the service is still up.
    let retry = tracker.observe(id, serviceReachable: true, tunnelActive: false)
    _ = tracker.observe(id, serviceReachable: false, tunnelActive: false)
    let afterServiceRestart = tracker.observe(id, serviceReachable: true, tunnelActive: false)
    #expect(first)
    #expect(!retry)
    #expect(afterServiceRestart)
}

@Test func shareLinksRejectDisguisedTargets() {
    func parse(_ link: String) -> AutomationCommand? { URL(string: link).flatMap(AutomationCommand.parse) }
    // Userinfo makes "localhost:3000" look like the host while the real host is 192.168.1.1.
    #expect(parse("opentraffic://share?url=http%3A%2F%2Flocalhost%3A3000%40192.168.1.1") == nil)
    // Newlines and bidi overrides could rewrite the confirmation text.
    #expect(parse("opentraffic://share?url=http%3A%2F%2Flocalhost%3A3000%0A%0AAllow") == nil)
    #expect(parse("opentraffic://share?port=3000&name=a%E2%80%AEb") == nil || parse("opentraffic://share?port=3000&name=a%E2%80%AEb") == .share(localURL: "http://localhost:3000", kind: .quick, name: nil))
    #expect(parse("opentraffic://share?url=file%3A%2F%2F%2Fetc") == nil)
    #expect(parse("opentraffic://share?url=http%3A%2F%2F127.0.0.1%3A8080") == .share(localURL: "http://127.0.0.1:8080", kind: .quick, name: nil))
    #expect(AutomationCommand.target(of: "http://localhost:3000")?.display == "localhost:3000")
    #expect(AutomationCommand.target(of: "http://localhost:3000")?.isLoopback == true)
    #expect(AutomationCommand.target(of: "http://192.168.1.20")?.isLoopback == false)
    #expect(AutomationCommand.target(of: "http://192.168.1.20")?.display == "192.168.1.20:80")
}

@Test func shareTargetLoopbackNeedsARealAddress() {
    for loopback in ["http://127.0.0.1:3000", "http://127.1.2.3", "http://localhost", "http://[::1]:8080", "http://app.localhost"] {
        #expect(AutomationCommand.target(of: loopback)?.isLoopback == true, "\(loopback)")
    }
    for remote in ["http://127.evil.com", "http://127.0.0.1.evil.com", "http://127.0.0.256", "http://127.0.0", "http://128.0.0.1", "http://127..0.1"] {
        #expect(AutomationCommand.target(of: remote)?.isLoopback != true, "\(remote)")
    }
    #expect(AutomationCommand.target(of: "http://[::1]:8080")?.display == "[::1]:8080")
}

@Test func automationFieldsDecodeWithDefaults() throws {
    let json = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Old","kind":"quick","localURL":"http://localhost:5173"}"#
    let definition = try JSONDecoder().decode(TunnelDefinition.self, from: Data(json.utf8))
    #expect(!definition.autoStart)
    #expect(definition.project == nil)
    #expect(TunnelDefinition(name: "x", kind: .quick, localURL: "http://localhost:1", project: "  ").project == nil)
    #expect(!NgrokAgent.isRetryable("failed: ERR_NGROK_334"))
    #expect(NgrokAgent.isRetryable("connection reset by peer"))
}

@Test func shareLinksCanTurnOnCollaboration() {
    let link = URL(string: "opentraffic://share?port=5173&collab=1")!
    #expect(AutomationCommand.parse(link) == .share(localURL: "http://localhost:5173", kind: .quick, name: nil, collaboration: true))
    let plain = URL(string: "opentraffic://share?port=5173")!
    #expect(AutomationCommand.parse(plain) == .share(localURL: "http://localhost:5173", kind: .quick, name: nil, collaboration: false))
}

@Test func linkTurnsOnTheLocalAPI() {
    #expect(AutomationCommand.parse(URL(string: "opentraffic://enable-api")!) == .enableAPI)
    #expect(AutomationCommand.parse(URL(string: "opentraffic://permissions")!) == .permissions)
    #expect(AutomationCommand.permissions.exposesService == false)
    #expect(AutomationCommand.parse(URL(string: "opentraffic:enable-api")!) == .enableAPI)
    // Turning the API on asks every time, so it doesn't count as quietly exposing anything.
    #expect(!AutomationCommand.enableAPI.exposesService)
}
