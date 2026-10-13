import Foundation
import Testing
@testable import OpenTrafficCore

// Shapes captured from ngrok 3.37.3 on a real Mac (domain replaced).
private let tunnelsJSON = #"""
{"tunnels":[{"name":"command_line","public_url":"https://example-name.ngrok-free.dev","proto":"https",
 "config":{"addr":"http://127.0.0.1:48123","inspect":true},
 "metrics":{"conns":{"count":4,"gauge":0,"rate1":0.01},"http":{"count":3,"rate1":0.05,"p50":1943750}}}],"uri":"/api/tunnels"}
"""#

private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

private var requestsJSON: String {
    """
    {"uri":"/api/requests/http","requests":[
     {"id":"airt_replayed","start":"2026-10-03T22:57:52+02:00","duration":2500000,"remote_addr":"replayed","tunnel_name":"command_line","uri":"/api/requests/http/airt_replayed",
      "request":{"method":"POST","proto":"HTTP/1.1","uri":"/webhook","headers":{"Content-Type":["application/json"],"Authorization":["Bearer secret"]},
                 "raw":"\(base64("POST /webhook HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer secret\r\n\r\n{\"event\":\"test\"}"))"},
      "response":{"status":"501 Unsupported method","status_code":501,"proto":"HTTP/1.0","headers":{"Server":["Python"]},"raw":"\(base64("HTTP/1.0 501\r\n\r\n"))"}},
     {"id":"airt_get","start":"2026-10-03T22:57:40+02:00","duration":1943750,"remote_addr":"203.0.113.9","tunnel_name":"command_line","uri":"/api/requests/http/airt_get",
      "request":{"method":"GET","proto":"HTTP/1.1","uri":"/?probe=1","headers":{"Accept":["*/*"],"Host":["example-name.ngrok-free.dev"]},"raw":"\(base64("GET /?probe=1 HTTP/1.1\r\n\r\n"))"},
      "response":{"status":"200 OK","status_code":200,"proto":"HTTP/1.0","headers":{},"raw":""}}
    ]}
    """
}

@Test func parsesTunnelsWithMetrics() throws {
    let tunnels = NgrokTunnelInfo.parse(Data(tunnelsJSON.utf8))
    let tunnel = try #require(tunnels.first)
    #expect(tunnel.publicURL == "https://example-name.ngrok-free.dev")
    #expect(tunnel.address == "http://127.0.0.1:48123")
    #expect(tunnel.totalConnections == 4)
    #expect(tunnel.totalRequests == 3)
    #expect(abs((tunnel.requestsPerMinute ?? 0) - 3) < 0.0001)
    #expect(NgrokTunnelInfo.parse(Data("{}".utf8)).isEmpty)
}

@Test func parsesRequestsNewestFirstWithBodiesAndReplays() throws {
    let requests = NgrokRequest.parse(Data(requestsJSON.utf8))
    #expect(requests.map(\.id) == ["airt_replayed", "airt_get"])
    let post = requests[0]
    #expect(post.method == "POST")
    #expect(post.uri == "/webhook")
    #expect(post.statusCode == 501)
    #expect(post.isReplay)
    #expect(abs((post.duration ?? 0) - 0.0025) < 0.000001)
    #expect(String(decoding: post.request.body, as: UTF8.self) == #"{"event":"test"}"#)
    #expect(post.request.headers.map(\.name) == ["Authorization", "Content-Type"])
    #expect(!requests[1].isReplay)
    #expect(requests[1].request.body.isEmpty)
}

@Test func curlExportOmitsSecretsAndKeepsBody() throws {
    let post = try #require(NgrokRequest.parse(Data(requestsJSON.utf8)).first)
    let curl = post.curlCommand(baseURL: "https://example-name.ngrok-free.dev/")
    #expect(curl.hasPrefix("curl -X 'POST' 'https://example-name.ngrok-free.dev/webhook'"))
    #expect(curl.contains("-H 'Content-Type: application/json'"))
    #expect(!curl.contains("secret"))
    #expect(curl.contains(#"--data-binary '{"event":"test"}'"#))
    #expect(NgrokRequest.isSensitive("COOKIE"))
}

@Test func curlExportQuotesAVisitorControlledMethod() throws {
    let hostile = requestsJSON.replacingOccurrences(of: #""method":"POST""#, with: #""method":"GET;touch /tmp/pwned;""#)
    let request = try #require(NgrokRequest.parse(Data(hostile.utf8)).first)
    #expect(request.curlCommand(baseURL: "https://x.ngrok.app").hasPrefix("curl -X 'GET;touch /tmp/pwned;' "))
}

@Test func buildsAgentArgumentsAndOverlay() {
    let arguments = NgrokAgent.arguments(localURL: "http://127.0.0.1:3000", domain: nil, configPaths: ["/a/ngrok.yml", "/b/overlay.yml"])
    #expect(arguments == ["http", "http://127.0.0.1:3000", "--log", "stdout", "--log-format", "json", "--config", "/a/ngrok.yml,/b/overlay.yml"])
    let fixed = NgrokAgent.arguments(localURL: "http://127.0.0.1:3000", domain: "me.ngrok.app", configPaths: ["/b/overlay.yml"])
    #expect(Array(fixed.suffix(2)) == ["--url", "https://me.ngrok.app"])
    #expect(NgrokAgent.overlayConfig(apiPort: 4567) == "version: \"3\"\nagent:\n  web_addr: 127.0.0.1:4567\n")
}

@Test func readsPublicURLFromStartedTunnelLine() {
    let raw = #"{"addr":"http://127.0.0.1:48123","lvl":"info","msg":"started tunnel","name":"command_line","obj":"tunnels","t":"2026-10-03T22:57:31+0200","url":"https://example-name.ngrok-free.dev"}"#
    #expect(NgrokAgent.publicURL(fromLogMessage: "started tunnel", rawLine: raw) == "https://example-name.ngrok-free.dev")
    #expect(NgrokAgent.publicURL(fromLogMessage: "client session established", rawLine: raw) == nil)
}

@Test func explainsKnownNgrokErrors() {
    #expect(NgrokAgent.explain("failed to start tunnel: The endpoint is already online.\nERR_NGROK_334").contains("one ngrok share at a time"))
    #expect(NgrokAgent.explain("authentication failed ERR_NGROK_4018").contains("authtoken"))
    #expect(NgrokAgent.explain("\n  something else\nmore") == "something else")
}

@Test func detectsAuthtokenWithoutReadingItBack() {
    #expect(NgrokAgent.hasAuthtoken(configText: "version: \"3\"\nagent:\n    authtoken: 2abcDEF_123\n"))
    #expect(!NgrokAgent.hasAuthtoken(configText: "version: \"3\"\nagent:\n  web_addr: 127.0.0.1:4040\n"))
    #expect(!NgrokAgent.hasAuthtoken(configText: "authtoken:\n"))
}

@Test func parsesNgrokLogLevelsAndTimestamps() {
    let entry = CloudflaredLogParser.parseLine(
        #"{"lvl":"eror","msg":"session closing","t":"2026-10-03T22:57:40+0200","err":"ERR_NGROK_334"}"#,
        stream: "stdout"
    )
    #expect(entry.level == "error")
    #expect(entry.message == "session closing")
    #expect(entry.timestamp == Date(timeIntervalSince1970: 1_791_061_060))
    #expect(StructuredLog.fields(fromRawLine: entry.rawLine).map(\.key) == ["err"])
}

// MARK: Body decoding

private let launches = #"{"status":"ok","launches":3}"#

private func message(_ head: String, body: Data, headers: [(name: String, values: [String])] = []) -> NgrokRequest.Message {
    NgrokRequest.Message(headers: headers, raw: Data((head + "\r\n\r\n").utf8) + body)
}

@Test func dechunksANodeResponseEvenWithoutTheHeaderInTheMap() {
    // Node's framing for a 28-byte JSON body. Go (and so ngrok) leaves Transfer-Encoding out of the header map.
    let response = message("HTTP/1.1 200 OK\r\nContent-Type: application/json", body: Data("1c\r\n\(launches)\r\n0\r\n\r\n".utf8))
    #expect(String(decoding: response.payload, as: UTF8.self) == launches)
    #expect(response.decodedBody == .init(data: Data(launches.utf8), encoding: nil))
    #expect(response.decodedBody.data.count == 28)

    let declared = message("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked", body: Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8))
    #expect(String(decoding: declared.payload, as: UTF8.self) == "hello world")
}

@Test func dechunkIgnoresExtensionsAndTrailers() {
    let framed = Data("4;name=\"a\"\r\nWiki\r\n5 ; x\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0;last\r\nExpires: never\r\nX-Checksum: abc\r\n\r\n".utf8)
    #expect(HTTPBodyDecoding.dechunk(framed).map { String(decoding: $0, as: UTF8.self) } == "Wikipedia in\r\n\r\nchunks.")
    #expect(HTTPBodyDecoding.dechunk(Data("0\r\n\r\n".utf8)) == Data())
}

@Test func malformedChunkingFallsBackToTheRawBody() {
    for body in [
        "zz\r\nhello\r\n0\r\n\r\n",   // size isn't hex
        "5\r\nhello world\r\n0\r\n\r\n", // chunk longer than declared
        "5\r\nhel",                    // truncated, and nothing declared it chunked
        "5\r\nhello\r\n0\r\n\r\nextra", // bytes after the message
        "0\r\nnot a trailer\r\n\r\n",
        "0\n",                         // plain text that happens to look like a last chunk
        "{\"a\":1}",
    ] {
        #expect(HTTPBodyDecoding.dechunk(Data(body.utf8)) == nil, "\(body)")
        let response = message("HTTP/1.1 200 OK", body: Data(body.utf8))
        #expect(response.payload == Data(body.utf8))
    }
    // Garbage under a chunked header is shown as it came.
    let declared = message("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked", body: Data("hello".utf8))
    #expect(declared.payload == Data("hello".utf8))
}

@Test func declaredChunkingKeepsWhatATruncatedCaptureHas() {
    let response = message("HTTP/1.1 200 OK", body: Data("5\r\nhello\r\n10\r\n wor".utf8),
                           headers: [(name: "Transfer-Encoding", values: ["chunked"])])
    #expect(String(decoding: response.payload, as: UTF8.self) == "hello wor")
}

@Test func decodesGzipAndDeflateContent() throws {
    let gzip = try #require(Data(base64Encoded: "H4sIAAAAAAAC/6tWKi5JLCktVrJSys9W0lHKSSzNS85IBfKNawGu+E16HAAAAA=="))
    let named = try #require(Data(base64Encoded: "H4sICAAAAAAC/2xhdW5jaGVzLmpzb24Aq1YqLkksKS1WslLKz1bSUcpJLM1LzkgF8o1rAa74TXocAAAA"))
    let zlib = try #require(Data(base64Encoded: "eJyrViouSSwpLVayUsrPVtJRykkszUvOSAXyjWsBiwMJaQ=="))
    let rawDeflate = try #require(Data(base64Encoded: "q1YqLkksKS1WslLKz1bSUcpJLM1LzkgF8o1rAQ=="))
    #expect(HTTPBodyDecoding.decode(gzip, contentEncoding: "gzip") == Data(launches.utf8))
    #expect(HTTPBodyDecoding.decode(named, contentEncoding: "x-gzip") == Data(launches.utf8))
    #expect(HTTPBodyDecoding.decode(zlib, contentEncoding: "deflate") == Data(launches.utf8))
    #expect(HTTPBodyDecoding.decode(rawDeflate, contentEncoding: "deflate") == Data(launches.utf8))
    #expect(HTTPBodyDecoding.decode(gzip.dropLast(12), contentEncoding: "gzip") == nil)

    // Chunked and gzipped together, the usual shape from a compressing server.
    let chunked = Data("\(String(gzip.count, radix: 16))\r\n".utf8) + gzip + Data("\r\n0\r\n\r\n".utf8)
    let response = message("HTTP/1.1 200 OK", body: chunked, headers: [(name: "Content-Encoding", values: ["gzip"])])
    #expect(response.decodedBody == .init(data: Data(launches.utf8), encoding: nil))
}

@Test func undecodableContentStaysMarkedAsCompressed() {
    let response = message("HTTP/1.1 200 OK", body: Data([0x1B, 0x2F, 0x00, 0xF8]),
                           headers: [(name: "Content-Encoding", values: ["br"])])
    #expect(response.decodedBody == .init(data: Data([0x1B, 0x2F, 0x00, 0xF8]), encoding: "br"))
    let corrupt = message("HTTP/1.1 200 OK", body: Data("not gzip".utf8), headers: [(name: "Content-Encoding", values: ["gzip"])])
    #expect(corrupt.decodedBody.encoding == "gzip")
}

@Test func curlExportSendsTheDechunkedBody() throws {
    let json = requestsJSON.replacingOccurrences(
        of: base64("POST /webhook HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer secret\r\n\r\n{\"event\":\"test\"}"),
        with: base64("POST /webhook HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"event\":\"test\"}\r\n0\r\n\r\n")
    )
    let post = try #require(NgrokRequest.parse(Data(json.utf8)).first)
    let curl = post.curlCommand(baseURL: "https://example-name.ngrok-free.dev")
    #expect(curl.hasSuffix(#"--data-binary '{"event":"test"}'"#))
    #expect(!curl.contains("Transfer-Encoding"))
}
