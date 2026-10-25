import Foundation
import Testing
@testable import OpenTrafficCore

// The endpoints behind the command-line tool: what the app's windows can do.

private func errorCode(_ data: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
}

@Test func reportsStatusServicesProjectsAndZones() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let status = try await api.object("GET", "/v1/status")
    #expect(status["version"] as? String == "9.9.9")
    let providers = try #require(status["providers"] as? [[String: Any]])
    #expect(providers.count == 2)
    // Ready, with a warning: the network blocks temporary tunnels.
    #expect(providers[0]["ready"] as? Bool == true)
    #expect((providers[0]["warning"] as? String)?.contains("1.1.1.1") == true)
    #expect(providers[1]["warning"] == nil)

    let services = try #require(try await api.object("GET", "/v1/services")["services"] as? [[String: Any]])
    #expect(services.first?["port"] as? Int == 5173)
    #expect(services.first?["sharedAs"] as? String == "Orbit")

    let projects = try #require(try await api.object("GET", "/v1/projects")["projects"] as? [[String: Any]])
    #expect(projects.first?["name"] as? String == "Demo")
    let started = try await api.object("POST", "/v1/projects/Demo/start")
    #expect(started["running"] as? Int == 1)
    let (_, missing) = try await api.request("POST", "/v1/projects/Nope/start")
    #expect(missing.statusCode == 404)
    let (_, wrongAction) = try await api.request("POST", "/v1/projects/Demo/pause")
    #expect(wrongAction.statusCode == 404)

    let zones = try #require(try await api.object("GET", "/v1/zones")["zones"] as? [[String: Any]])
    #expect(zones.first?["name"] as? String == "example.com")
}

@Test func readsEditsRestartsAndRemovesAShare() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let detail = try await api.object("GET", "/v1/shares/orbit")
    #expect(detail["name"] as? String == "Orbit")

    let renamed = try await api.object("PATCH", "/v1/shares/Orbit", json: #"{"name":"Orbit 2","project":"Demo"}"#)
    #expect(renamed["name"] as? String == "Orbit 2")
    #expect(renamed["project"] as? String == "Demo")

    let (_, restarted) = try await api.request("POST", "/v1/shares/Orbit%202/restart")
    #expect(restarted.statusCode == 200)

    let (_, wrongMethod) = try await api.request("PUT", "/v1/shares/Orbit%202")
    #expect(wrongMethod.statusCode == 405)

    let deleted = try await api.object("DELETE", "/v1/shares/Orbit%202")
    #expect(deleted["deleted"] as? Bool == true)
    let (_, gone) = try await api.request("GET", "/v1/shares/Orbit%202")
    #expect(gone.statusCode == 404)
}

@Test func setsProtectionAndShowsThePassword() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    #expect(try await api.object("GET", "/v1/shares/Orbit/protection")["mode"] as? String == "none")
    let protected = try await api.object("PUT", "/v1/shares/Orbit/protection", json: #"{"mode":"password","username":"guest"}"#)
    #expect(protected["password"] as? String == "s3cret")
    let renewed = try await api.object("POST", "/v1/shares/Orbit/password")
    #expect(renewed["password"] as? String == "n3w")

    let (unsupported, response) = try await api.request("PUT", "/v1/shares/Orbit/protection", json: #"{"mode":"google"}"#)
    #expect(response.statusCode == 400)
    #expect(errorCode(unsupported) == "bad_request")
    let (_, missingMode) = try await api.request("PUT", "/v1/shares/Orbit/protection", json: "{}")
    #expect(missingMode.statusCode == 400)
}

@Test func deletesAComment() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let deleted = try await api.object("DELETE", "/v1/shares/Orbit/comments/c1")
    #expect(deleted["deleted"] as? Bool == true)
    let all = try #require(try await api.object("GET", "/v1/shares/Orbit/comments?status=all")["comments"] as? [[String: Any]])
    #expect(all.map { $0["id"] as? String } == ["c2"])
    let (_, again) = try await api.request("DELETE", "/v1/shares/Orbit/comments/c1")
    #expect(again.statusCode == 404)
}

@Test func domainSharesNeedAHostname() async throws {
    let api = try await APIHarness.start()
    defer { Task { await api.stop() } }

    let (data, response) = try await api.request("POST", "/v1/shares", json: #"{"port":3000,"provider":"domain"}"#)
    #expect(response.statusCode == 400)
    #expect(errorCode(data) == "bad_request")
    let (_, accepted) = try await api.request("POST", "/v1/shares", json: #"{"port":3000,"provider":"domain","hostname":"app.example.com","replaceDNS":true}"#)
    #expect(accepted.statusCode == 200)
}

@Test func backendsWithoutTheNewOperationsAnswerNotSupported() async throws {
    struct Minimal: OpenTrafficAPIBackend {
        func listShares() async -> [APIShare] { [] }
        func createShare(_ request: APIShareRequest, client: String) async throws -> APIShare { throw OpenTrafficAPIError.badRequest("no") }
        func startShare(_ share: String, client: String) async throws -> APIShare { throw OpenTrafficAPIError.badRequest("no") }
        func stopShare(_ share: String) async throws -> APIShare { throw OpenTrafficAPIError.badRequest("no") }
        func comments(_ share: String, status: APICommentStatus) async throws -> [APIComment] { [] }
        func screenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String) { throw OpenTrafficAPIError.badRequest("no") }
        func resolveComment(_ share: String, commentID: String, resolved: Bool) async throws -> APIComment { throw OpenTrafficAPIError.badRequest("no") }
        func reply(_ share: String, commentID: String, text: String, client: String) async throws -> APIComment { throw OpenTrafficAPIError.badRequest("no") }
        func errors(_ share: String) async throws -> [CollabErrorGroup] { [] }
        func logs(_ share: String, lines: Int) async throws -> [String] { [] }
    }
    let router = APIRouter(backend: Minimal(), events: APIEventLog())
    #expect(await router.respond(method: "GET", uri: "/v1/status", body: Data(), client: "test").status == 501)
    #expect(await router.respond(method: "GET", uri: "/v1/zones", body: Data(), client: "test").status == 501)
    #expect(await router.respond(method: "GET", uri: "/v1/shares/Orbit", body: Data(), client: "test").status == 404)
}

// MARK: Mac apps

/// A backend with one Mac app share and one Mac app found on this Mac; records what it was asked.
private final class MacAppBackend: OpenTrafficAPIBackend, @unchecked Sendable {
    static let shareID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    private let lock = NSLock()
    private var recordedRequests: [APIShareRequest] = []
    private var recordedRestarts: [(share: String, resetData: Bool)] = []

    var requests: [APIShareRequest] { lock.withLock { recordedRequests } }
    var restarts: [(share: String, resetData: Bool)] { lock.withLock { recordedRestarts } }

    let share = APIShare(
        id: shareID, name: "Orbit", provider: "opentunnel", kind: "opentunnel", state: "running",
        localURL: "http://127.0.0.1/", publicURL: "https://orbit.opentunnel.xyz", collaboration: true, people: [],
        openComments: 0, comments: 0,
        macApp: APIShareMacApp(path: "/Users/me/code/Orbit/build/Orbit.app", name: "Orbit", data: "copy", state: "running", viewers: 2, warning: "Orbit dropped an entitlement.")
    )

    func listShares() async -> [APIShare] { [share] }
    func createShare(_ request: APIShareRequest, client: String) async throws -> APIShare {
        lock.withLock { recordedRequests.append(request) }
        return share
    }
    func startShare(_ share: String, client: String) async throws -> APIShare { self.share }
    func stopShare(_ share: String) async throws -> APIShare { self.share }
    func comments(_ share: String, status: APICommentStatus) async throws -> [APIComment] { [] }
    func screenshot(_ share: String, commentID: String) async throws -> (data: Data, contentType: String) { throw OpenTrafficAPIError.notFound("no") }
    func resolveComment(_ share: String, commentID: String, resolved: Bool) async throws -> APIComment { throw OpenTrafficAPIError.notFound("no") }
    func reply(_ share: String, commentID: String, text: String, client: String) async throws -> APIComment { throw OpenTrafficAPIError.notFound("no") }
    func errors(_ share: String) async throws -> [CollabErrorGroup] { [] }
    func logs(_ share: String, lines: Int) async throws -> [String] { [] }

    func localServices() async -> [APILocalService] {
        [APILocalService(port: 3000, url: "http://localhost:3000", title: "Docs", process: "node", statusCode: 200, upSince: nil, sharedAs: nil)]
    }

    func macApps() async -> [APIMacApp] {
        [APIMacApp(MacApp(name: "Orbit", bundle: URL(fileURLWithPath: "/Users/me/code/Orbit/build/Orbit.app"), bundleIdentifier: "se.example.orbit",
                          projectDirectory: URL(fileURLWithPath: "/Users/me/code/Orbit"), isRunning: true, pid: 42), sharedAs: "Orbit")]
    }

    func restartMacApp(_ share: String, resetData: Bool, client: String) async throws -> APIShare {
        guard share.caseInsensitiveCompare("Orbit") == .orderedSame else { throw OpenTrafficAPIError.notFound("No share named “\(share)”.") }
        lock.withLock { recordedRestarts.append((share, resetData)) }
        return self.share
    }
}

private func json(_ response: APIResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

@Test func servicesListMacAppsWithTheirBundleAndProject() async throws {
    let router = APIRouter(backend: MacAppBackend(), events: APIEventLog())
    let body = try json(await router.respond(method: "GET", uri: "/v1/services", body: Data(), client: "test"))
    // Web servers stay where they were, so older scripts keep working.
    let services = try #require(body["services"] as? [[String: Any]])
    #expect(services.first?["port"] as? Int == 3000)
    let apps = try #require(body["apps"] as? [[String: Any]])
    #expect(apps.count == 1)
    #expect(apps[0]["kind"] as? String == "macapp")
    #expect(apps[0]["name"] as? String == "Orbit")
    #expect(apps[0]["bundle"] as? String == "/Users/me/code/Orbit/build/Orbit.app")
    #expect(apps[0]["projectDirectory"] as? String == "/Users/me/code/Orbit")
    #expect(apps[0]["running"] as? Bool == true)
    #expect(apps[0]["sharedAs"] as? String == "Orbit")
    // A backend that doesn't know Mac apps lists none.
    let minimal = APIRouter(backend: FakeAPIBackend(), events: APIEventLog())
    #expect(try json(await minimal.respond(method: "GET", uri: "/v1/services", body: Data(), client: "test"))["apps"] as? [Any] != nil)
}

@Test func sharesAMacAppByPathOrName() async throws {
    let backend = MacAppBackend()
    let router = APIRouter(backend: backend, events: APIEventLog())
    let created = await router.respond(method: "POST", uri: "/v1/shares", body: Data(#"{"macApp":"Orbit","provider":"opentunnel","macAppData":"empty"}"#.utf8), client: "test")
    #expect(created.status == 200)
    let share = try json(created)
    let app = try #require(share["macApp"] as? [String: Any])
    #expect(app["path"] as? String == "/Users/me/code/Orbit/build/Orbit.app")
    #expect(app["state"] as? String == "running")
    #expect(app["viewers"] as? Int == 2)
    #expect(app["data"] as? String == "copy")
    #expect(app["warning"] as? String == "Orbit dropped an entitlement.")
    let byPath = await router.respond(method: "POST", uri: "/v1/shares", body: Data(#"{"macApp":"/Users/me/code/Orbit/build/Orbit.app"}"#.utf8), client: "test")
    #expect(byPath.status == 200)
    #expect(backend.requests.map(\.macApp) == ["Orbit", "/Users/me/code/Orbit/build/Orbit.app"])
    #expect(backend.requests.map(\.macAppData) == ["empty", nil])
    #expect(backend.requests.first?.provider == "opentunnel")
    // An .app path as `url` still reaches the app, which tells Electron apps and Mac apps apart.
    let asURL = await router.respond(method: "POST", uri: "/v1/shares", body: Data(#"{"url":"/Users/me/code/Orbit/build/Orbit.app","macAppData":"empty"}"#.utf8), client: "test")
    #expect(asURL.status == 200)
}

@Test func refusesMacAppRequestsThatCantWork() async throws {
    let backend = MacAppBackend()
    let router = APIRouter(backend: backend, events: APIEventLog())
    func message(_ body: String) async throws -> (Int, String?) {
        let response = await router.respond(method: "POST", uri: "/v1/shares", body: Data(body.utf8), client: "test")
        return (response.status, (try json(response)["error"] as? [String: Any])?["message"] as? String)
    }
    #expect(try await message(#"{"macApp":"Orbit","port":3000}"#) == (400, "Give a Mac app, or a port or url, not both"))
    #expect(try await message(#"{"macApp":"Orbit","provider":"ngrok"}"#) == (400, "Mac apps are shared with quick or opentunnel"))
    #expect(try await message(#"{"macApp":"Orbit","provider":"tailscale"}"#).0 == 400)
    #expect(try await message(#"{"macApp":"  "}"#) == (400, "macApp is empty"))
    #expect(try await message(#"{"macApp":"Orbit","start":false}"#).0 == 400)
    #expect(try await message(#"{"macApp":"Orbit","macAppData":"fresh"}"#) == (400, "macAppData must be copy or empty"))
    #expect(try await message(#"{"port":3000,"macAppData":"empty"}"#) == (400, "macAppData is for Mac apps"))
    #expect(try await message(#"{"macApp":42}"#).0 == 400)
    #expect(try await message("{}") == (400, "Give a port, a url, or a Mac app"))
    #expect(backend.requests.isEmpty)
    // Quick and its aliases are fine.
    #expect(try await message(#"{"macApp":"Orbit","provider":"temporary"}"#).0 == 200)
}

@Test func restartsOrResetsASharedMacApp() async throws {
    let backend = MacAppBackend()
    let router = APIRouter(backend: backend, events: APIEventLog())
    #expect(await router.respond(method: "POST", uri: "/v1/shares/orbit/restart-app", body: Data(), client: "test").status == 200)
    #expect(await router.respond(method: "POST", uri: "/v1/shares/Orbit/reset-data", body: Data(), client: "test").status == 200)
    #expect(backend.restarts.map { $0.resetData } == [false, true])
    #expect(await router.respond(method: "GET", uri: "/v1/shares/Orbit/restart-app", body: Data(), client: "test").status == 405)
    #expect(await router.respond(method: "POST", uri: "/v1/shares/Nope/restart-app", body: Data(), client: "test").status == 404)
    // Older backends answer that they can't.
    let minimal = APIRouter(backend: FakeAPIBackend(), events: APIEventLog())
    #expect(await minimal.respond(method: "POST", uri: "/v1/shares/Orbit/restart-app", body: Data(), client: "test").status == 501)
}

@Test func mcpSharesAndRestartsMacApps() async throws {
    let backend = MacAppBackend()
    let mcp = MCPServer(backend: backend, events: APIEventLog())
    func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        try #require(await mcp.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]], client: "test")?["result"])
    }
    let listed = try #require(await mcp.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], client: "test")?["result"]?["tools"]?.arrayValue)
    let share = try #require(listed.first { $0["name"] == "share" })
    #expect(share["inputSchema"]?["properties"]?["mac_app"]?["type"] == "string")
    #expect(share["inputSchema"]?["properties"]?["mac_app_data"]?["enum"] == ["copy", "empty"])
    let restart = try #require(listed.first { $0["name"] == "restart_mac_app" })
    #expect(restart["inputSchema"]?["required"] == ["share"])

    let shared = try await call("share", ["mac_app": "Orbit", "mac_app_data": "empty", "provider": "opentunnel"])
    #expect(shared["isError"] == nil)
    #expect(shared["structuredContent"]?["macApp"]?["name"] == "Orbit")
    #expect(backend.requests.first?.macApp == "Orbit")
    #expect(backend.requests.first?.macAppData == "empty")
    #expect(try await call("share", ["mac_app": "Orbit", "port": 3000])["isError"] == true)

    #expect(try await call("restart_mac_app", ["share": "Orbit"])["isError"] == nil)
    #expect(try await call("restart_mac_app", ["share": "Orbit", "reset_data": true])["isError"] == nil)
    #expect(backend.restarts.map { $0.resetData } == [false, true])
    #expect(try await call("restart_mac_app", [:])["isError"] == true)
}

@Test func macAppNamesAndPathsAreToldApart() {
    #expect(APIMacAppReference("Orbit") == .name("Orbit"))
    #expect(APIMacAppReference(" Orbit Studio ") == .name("Orbit Studio"))
    #expect(APIMacAppReference("/Users/me/code/Orbit/build/Orbit.app") == .path("/Users/me/code/Orbit/build/Orbit.app"))
    #expect(APIMacAppReference("~/code/Orbit.app") == .path("~/code/Orbit.app"))
    #expect(APIMacAppReference("Orbit.app") == .path("Orbit.app"))
}

@Test func macAppNamesMatchTheListedApp() {
    func app(_ name: String, _ path: String, running: Bool = false) -> MacApp {
        MacApp(name: name, bundle: URL(fileURLWithPath: path), bundleIdentifier: nil, projectDirectory: nil, isRunning: running)
    }
    let orbit = app("Orbit", "/p/Orbit/build/Orbit.app", running: true)
    let notes = app("Field Notes", "/p/Notes/build/NotesApp.app")
    #expect(APIMacAppReference.match("orbit", in: [orbit, notes]) == .found(orbit))
    #expect(APIMacAppReference.match("field notes", in: [orbit, notes]) == .found(notes))
    // By the bundle's file name too.
    #expect(APIMacAppReference.match("NotesApp", in: [orbit, notes]) == .found(notes))
    #expect(APIMacAppReference.match("Atlas", in: [orbit, notes]) == .none)
    // Two projects with an app of that name: the running one, or ask for the path.
    let otherOrbit = app("Orbit", "/q/Orbit/build/Orbit.app")
    #expect(APIMacAppReference.match("Orbit", in: [orbit, otherOrbit]) == .found(orbit))
    let stoppedOrbit = app("Orbit", "/p/Orbit/build/Orbit.app")
    #expect(APIMacAppReference.match("Orbit", in: [stoppedOrbit, otherOrbit]) == .ambiguous([stoppedOrbit, otherOrbit]))
}

@Test func missingPermissionsSayWhichAndWhere() {
    let both = OpenTrafficAPIError.missingMacAppPermissions([.accessibility, .screenRecording])
    #expect(both.status == 409)
    #expect(both.code == "missing_permissions")
    #expect(both.message.hasPrefix("OpenTraffic needs Accessibility and Screen & System Audio Recording to share Mac apps. Turn them on"))
    #expect(both.message.contains("System Settings → Privacy & Security"))
    #expect(both.message.contains("`opentraffic permissions`"))
    let one = OpenTrafficAPIError.missingMacAppPermissions([.screenRecording], wizardOpened: true)
    #expect(one.message.hasPrefix("OpenTraffic needs Screen & System Audio Recording to share Mac apps. Turn it on"))
    #expect(one.message.contains("OpenTraffic opened a window that walks you through it"))
}

@Test func macAppSessionStatesHaveAPINames() {
    #expect(APIShareMacApp.describe(.idle) == ("starting", nil))
    #expect(APIShareMacApp.describe(.running) == ("running", nil))
    #expect(APIShareMacApp.describe(.restarting) == ("restarting", nil))
    #expect(APIShareMacApp.describe(.crashed("Orbit quit unexpectedly.")) == ("crashed", "Orbit quit unexpectedly."))
    #expect(APIShareMacApp.describe(.failed("No window.")) == ("failed", "No window."))
    #expect(APIShareMacApp.describe(.stopped) == ("stopped", nil))
}
