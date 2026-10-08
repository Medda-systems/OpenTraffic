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
