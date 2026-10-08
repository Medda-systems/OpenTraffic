import Foundation
import Testing
@testable import OpenTrafficCore

private func checks(_ pairs: [(HealthCheckKind, HealthCheckState)]) -> [TunnelHealthCheck] {
    pairs.map { TunnelHealthCheck(kind: $0.0, state: $0.1, detail: "\($0.0.rawValue) detail") }
}

@Test func remotePathMapsChecksToStagesInFlowOrder() {
    let stages = ConnectionPath.stages(
        checks: checks([(.connector, .ok), (.localOrigin, .failed), (.edge, .ok), (.dns, .ok), (.publicSite, .failed)]),
        kind: .remote,
        localLabel: ":5174",
        publicLabel: "landing.example.dev"
    )
    #expect(stages.map(\.kind) == [.localService, .connector, .edge, .publicSite])
    #expect(stages.map(\.state) == [.failed, .ok, .ok, .failed])
    #expect(stages[0].title == ":5174")
    #expect(stages[3].sourceCheck?.kind == .publicSite)
}

@Test func failedDNSDecidesThePublicStage() {
    let stages = ConnectionPath.stages(
        checks: checks([(.connector, .ok), (.localOrigin, .ok), (.edge, .ok), (.dns, .failed), (.publicSite, .ok)]),
        kind: .remote,
        localLabel: "",
        publicLabel: ""
    )
    #expect(stages[3].state == .failed)
    #expect(stages[3].sourceCheck?.kind == .dns)
}

@Test func quickTunnelEdgeFollowsTheConnector() {
    let running = ConnectionPath.stages(
        checks: checks([(.connector, .ok), (.localOrigin, .ok), (.edge, .skipped)]),
        kind: .quick, localLabel: "", publicLabel: ""
    )
    #expect(running[2].state == .ok)
    #expect(running[2].sourceCheck == nil)
    let stopped = ConnectionPath.stages(
        checks: checks([(.connector, .skipped)]),
        kind: .quick, localLabel: "", publicLabel: ""
    )
    #expect(stopped[2].state == .skipped)
}

@Test func linksFlowOnlyBetweenHealthyStages() {
    let stages = ConnectionPath.stages(
        checks: checks([(.connector, .ok), (.localOrigin, .ok), (.edge, .failed)]),
        kind: .remote, localLabel: "", publicLabel: ""
    )
    #expect(ConnectionPath.isLinkFlowing(from: stages[0], to: stages[1]))
    #expect(!ConnectionPath.isLinkFlowing(from: stages[1], to: stages[2]))
}

@Test func structuredLogFieldsSkipConsumedKeysAndPrioritizeUsefulOnes() {
    let raw = #"{"level":"info","message":"Registered tunnel connection","time":"2026-10-03T18:15:09Z","zeta":"z","location":"arn02","connIndex":0,"protocol":"quic","nested":{"b":1}}"#
    let fields = StructuredLog.fields(fromRawLine: raw)
    #expect(fields.map(\.key) == ["connIndex", "location", "protocol", "nested", "zeta"])
    #expect(fields.first?.value == "0")
    #expect(fields.first(where: { $0.key == "nested" })?.value == #"{"b":1}"#)
    #expect(StructuredLog.fields(fromRawLine: "plain text line").isEmpty)
    #expect(StructuredLog.fields(fromRawLine: nil).isEmpty)
}

@Test func structuredLogTidiesTableMessages() {
    #expect(StructuredLog.displayMessage("|  TCP Connectivity  region1.v2.argotunnel.com  PASS   |") == "TCP Connectivity  region1.v2.argotunnel.com  PASS")
    #expect(StructuredLog.displayMessage("Starting tunnel") == "Starting tunnel")
}

@Test func faviconLocatorPrefersAppleTouchThenBitmapIcons() {
    let base = URL(string: "http://localhost:5173/app/")!
    let html = """
    <head>
    <link rel="stylesheet" href="/style.css">
    <link rel="icon" type="image/svg+xml" href="/vite.svg">
    <link rel='shortcut icon' href='favicon.png'>
    </head>
    """
    #expect(FaviconLocator.iconURL(html: html, baseURL: base).absoluteString == "http://localhost:5173/app/favicon.png")
    let touch = html + #"<link href="/touch.png" rel="apple-touch-icon">"#
    #expect(FaviconLocator.iconURL(html: touch, baseURL: base).absoluteString == "http://localhost:5173/touch.png")
}

@Test func faviconLocatorFallsBackToFaviconIco() {
    let base = URL(string: "http://127.0.0.1:3000/")!
    #expect(FaviconLocator.iconURL(html: "<html></html>", baseURL: base).absoluteString == "http://127.0.0.1:3000/favicon.ico")
    #expect(FaviconLocator.iconURL(html: #"<link rel="icon" href="javascript:alert(1)">"#, baseURL: base).absoluteString == "http://127.0.0.1:3000/favicon.ico")
}

@Test func menuBarStatePrioritizesAttention() {
    #expect(MenuBarIconState.resolve(activeTunnels: 0, needsAttention: false) == .idle)
    #expect(MenuBarIconState.resolve(activeTunnels: 2, needsAttention: false) == .live)
    #expect(MenuBarIconState.resolve(activeTunnels: 2, needsAttention: true) == .attention)
}
