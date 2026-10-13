import Foundation
import Testing
@testable import OpenTrafficCore

@Test func parsesChunkBoundariesAndPreservesStructuredLog() {
    var parser = CloudflaredLogParser()
    let first = parser.append(Data(#"{"level":"info","message":"Registered tunnel""#.utf8), stream: "stderr")
    #expect(first.isEmpty)
    let second = parser.append(Data(",\"connIndex\":1,\"location\":\"arn02\"}\n".utf8), stream: "stderr")
    #expect(second.count == 1)
    #expect(second[0].message == "Registered tunnel")
    #expect(second[0].rawLine?.contains("connIndex") == true)
    #expect(second[0].level == "info")
}

@Test func redactsTokensInTextJSONAndMapOutput() {
    let source = #"Authorization: Bearer abc.def token=supersecret Settings: map[token:another] tunnel_token=last"#
    let redacted = SecretRedactor.redact(source)
    #expect(!redacted.contains("abc.def"))
    #expect(!redacted.contains("supersecret"))
    #expect(!redacted.contains("another"))
    #expect(!redacted.contains("last"))
    #expect(redacted.contains("<redacted>"))
}

@Test func redactsKnownSecretEvenWhenLogHasNoTokenLabel() {
    var parser = CloudflaredLogParser(secrets: ["connector-secret-value"])
    let entries = parser.append(Data("diagnostic connector-secret-value leaked\n".utf8), stream: "stderr")
    #expect(entries.count == 1)
    #expect(entries[0].message == "diagnostic <redacted> leaked")
}

@Test func boundsLogEntriesAndPendingBytes() {
    var buffer = BoundedLogBuffer(capacity: 2)
    buffer.append(contentsOf: [
        TunnelLogEntry(message: "one"),
        TunnelLogEntry(message: "two"),
        TunnelLogEntry(message: "three"),
    ])
    #expect(buffer.entries.map(\.message) == ["two", "three"])

    var parser = CloudflaredLogParser()
    let entries = parser.append(Data(repeating: 65, count: CloudflaredLogParser.maximumPendingBytes + 1), stream: "stdout")
    #expect(entries.count == 1)
    #expect(entries[0].message.hasSuffix("<line truncated>"))
}

@Test func bufferKeepsItsErrorCountAsLinesRollOff() {
    var buffer = BoundedLogBuffer(capacity: 3)
    buffer.append(contentsOf: [
        TunnelLogEntry(level: "error", message: "a"),
        TunnelLogEntry(level: "info", message: "b"),
        TunnelLogEntry(level: "ERROR", message: "c"),
    ])
    #expect(buffer.errorCount == 2)
    buffer.append(contentsOf: [TunnelLogEntry(level: "warn", message: "d")])
    #expect(buffer.errorCount == 1)
    buffer.removeAll()
    #expect(buffer.errorCount == 0)
}

// MARK: Why cloudflared exited

@Test func explainsAQuickTunnelThatGotNoAddress() {
    var parser = CloudflaredLogParser()
    let entries = parser.append(Data("""
    {"level":"info","time":"2026-10-13T21:18:00Z","message":"Requesting new quick Tunnel on trycloudflare.com..."}
    failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": context deadline exceeded

    """.utf8), stream: "stderr")
    let reason = CloudflaredFailure.reason(in: entries)
    #expect(reason == #"failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": context deadline exceeded"#)
    #expect(reason.map(CloudflaredFailure.isQuickTunnelRequest) == true)
    let message = CloudflaredFailure.message(reason: reason, status: 1)
    #expect(message.hasPrefix("Cloudflare didn't hand out a temporary address (api.trycloudflare.com didn't answer)"))
    #expect(CloudflaredFailure.message(reason: "failed to request quick Tunnel: dial tcp: lookup api.trycloudflare.com: no such host", status: 1).contains("couldn't be looked up"))
    #expect(CloudflaredFailure.message(reason: "failed to unmarshal quick Tunnel: invalid character '<'", status: 1).contains("unexpected answer"))
}

@Test func otherExitsSayWhatCloudflaredSaidLast() {
    let entries = [
        CloudflaredLogParser.parseLine(#"{"level":"info","message":"Starting tunnel"}"#, stream: "stderr"),
        CloudflaredLogParser.parseLine(#"{"level":"error","error":"Unauthorized: Invalid tunnel secret","message":"Register tunnel error from server side"}"#, stream: "stderr"),
        CloudflaredLogParser.parseLine(#"{"level":"info","message":"Retrying connection"}"#, stream: "stderr"),
    ]
    let reason = CloudflaredFailure.reason(in: entries)
    #expect(reason == "Register tunnel error from server side: Unauthorized: Invalid tunnel secret")
    #expect(reason.map(CloudflaredFailure.isQuickTunnelRequest) == false)
    #expect(CloudflaredFailure.message(reason: reason, status: 1) == "cloudflared stopped: Register tunnel error from server side: Unauthorized: Invalid tunnel secret.")
    #expect(CloudflaredFailure.message(reason: nil, status: 2) == "cloudflared exited with status 2.")
}
