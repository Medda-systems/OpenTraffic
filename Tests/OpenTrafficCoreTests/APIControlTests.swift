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
    #expect((status["providers"] as? [[String: Any]])?.count == 2)

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
