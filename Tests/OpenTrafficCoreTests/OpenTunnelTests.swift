import Foundation
import Testing
@testable import OpenTrafficCore

@Test func routeNamesAreDNSLabelsThatDontClash() {
    #expect(OpenTunnel.routeName(for: "Orbit Dashboard", taken: []) == "orbit-dashboard")
    #expect(OpenTunnel.routeName(for: "localhost:5173", taken: []) == "localhost-5173")
    #expect(OpenTunnel.routeName(for: "  ✨ ", taken: []) == "site")
    #expect(OpenTunnel.routeName(for: "Orbit", taken: ["orbit", "orbit-2"]) == "orbit-3")
    #expect(OpenTunnel.routeName(for: String(repeating: "a", count: 90), taken: []).count <= 56)
    #expect(OpenTunnel.isValidRoute("orbit-dashboard"))
    #expect(OpenTunnel.isValidRoute("@"))
    #expect(!OpenTunnel.isValidRoute("Orbit"))
    #expect(!OpenTunnel.isValidRoute("-orbit"))
    #expect(!OpenTunnel.isValidRoute(""))
}

@Test func onlyHTTPOriginsBecomeRouteTargets() {
    #expect(OpenTunnel.target(for: "http://localhost:5173") == "127.0.0.1:5173")
    #expect(OpenTunnel.target(for: "http://[::1]:5173") == "[::1]:5173")
    #expect(OpenTunnel.target(for: "http://192.168.1.20") == "192.168.1.20:80")
    #expect(OpenTunnel.target(for: "https://localhost:8443") == nil)
    #expect(OpenTunnel.url(route: "web", hostname: "abc.opentunnel.xyz") == "https://web.abc.opentunnel.xyz")
    #expect(OpenTunnel.url(route: "@", hostname: "abc.opentunnel.xyz") == "https://abc.opentunnel.xyz")
}

@Test func theRouteURLIsReadFromTheCLIOutput() {
    let output = """
    Creating tunnel...
    Waiting for certificate verification (this can take a few minutes)........
    Tunnel is ready.
    Added route web → 127.0.0.1:47811
    https://web.k3v9qx2mz7ab.opentunnel.xyz
    """
    #expect(OpenTunnel.publicURL(inOutput: output) == "https://web.k3v9qx2mz7ab.opentunnel.xyz")
    #expect(OpenTunnel.publicURL(inOutput: "Added route web") == nil)
}

@Test func serviceStatusIsParsedFromTheControlSocketAnswer() throws {
    let json = #"{"ok":true,"status":{"pid":38321,"version":"0.2.2","profile":"opentraffic","phase":"running","tunnel":{"state":"connected","hostname":"abc.opentunnel.xyz","routes":{"web":"127.0.0.1:47811"},"session":"s","connections":2,"last_error":null,"connected_at":1},"started_at":1}}"#
    let status = try #require(OpenTunnelStatus.parse(Data(json.utf8)))
    #expect(status.isConnected)
    #expect(status.version == "0.2.2")
    #expect(status.routes == ["web": "127.0.0.1:47811"])
    #expect(status.connections == 2)
    #expect(status.lastError == nil)

    let stopped = try #require(OpenTunnelStatus.parse(Data(#"{"ok":true,"status":{"pid":1,"version":"0.2.2","profile":"opentraffic","phase":"stopped","last_error":"relay refused","started_at":1}}"#.utf8)))
    #expect(stopped.phase == .stopped)
    #expect(!stopped.isConnected)
    #expect(stopped.lastError == "relay refused")
    #expect(OpenTunnelStatus.parse(Data(#"{"ok":false,"error":"nope"}"#.utf8)) == nil)
}

@Test func routesAreReadFromTheProfileConfig() {
    let toml = """
    # routes
    [routes]
    web = "127.0.0.1:47811"
    "@" = "127.0.0.1:8080"
    api = '127.0.0.1:3000'

    [other]
    ignored = "x"
    """
    #expect(OpenTunnel.parseRoutes(toml) == ["web": "127.0.0.1:47811", "@": "127.0.0.1:8080", "api": "127.0.0.1:3000"])
    #expect(OpenTunnel.configuredRoutes(at: URL(fileURLWithPath: "/nonexistent/opentraffic.toml")).isEmpty)
}

@Test func theStatusQueryIsNilWithoutAService() {
    #expect(OpenTunnelStatus.query(socket: URL(fileURLWithPath: "/tmp/no-such-opentunnel.sock")) == nil)
}

@Test func routeRecordsRoundTrip() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "opentunnel-routes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let persistence = OpenTunnelRouteRecordPersistence(fileURL: file)
    let records = [OpenTunnelRouteRecord(tunnelID: UUID(), route: "web", target: "127.0.0.1:47811")]
    try persistence.save(records)
    #expect(persistence.load() == records)
}

@Test func openTunnelSharesKeepTheirRouteAcrossSaves() throws {
    let definition = TunnelDefinition(name: "Orbit", kind: .opentunnel, localURL: "http://localhost:5173", openTunnelRoute: "orbit")
    let decoded = try JSONDecoder().decode(TunnelDefinition.self, from: JSONEncoder().encode(definition))
    #expect(decoded.openTunnelRoute == "orbit")
    #expect(decoded.kind.provider == .opentunnel)
    #expect(decoded.kind.supportsCollaboration)
    #expect(!decoded.kind.hasEphemeralURL)
}

@Test func filesAreFoundWhereTheCLIPutsThem() {
    let plain = OpenTunnel.Paths(environment: ["HOME": "/Users/sam", "TMPDIR": "/var/folders/x/T/"])
    #expect(plain.identity.path == "/Users/sam/.local/share/opentunnel/opentraffic/tunnel.json")
    #expect(plain.routes.path == "/Users/sam/.config/opentunnel/opentraffic.toml")
    #expect(plain.log.path == "/Users/sam/.local/state/opentunnel/opentraffic/daemon.log")
    #expect(plain.socket.path == "/var/folders/x/T/opentunnel-\(getuid())/opentraffic.sock")
    let xdg = OpenTunnel.Paths(environment: ["HOME": "/Users/sam", "XDG_CONFIG_HOME": "/c", "XDG_DATA_HOME": "/d", "XDG_STATE_HOME": "/s", "XDG_RUNTIME_DIR": "/r"])
    #expect(xdg.routes.path == "/c/opentunnel/opentraffic.toml")
    #expect(xdg.identity.path == "/d/opentunnel/opentraffic/tunnel.json")
    #expect(xdg.socket.path == "/r/opentunnel/opentraffic.sock")
}
