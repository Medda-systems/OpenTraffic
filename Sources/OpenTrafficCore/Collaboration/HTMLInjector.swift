import Foundation

/// Inserts OpenTraffic's snippets into a streamed HTML document: `headStart` right after the opening
/// `<head>` tag (so it runs before the page's own scripts) and `headEnd` before `</head>` or `<body`,
/// whichever comes first. Without those tags both go at that point or at the end. Only the bytes
/// before the insertion point are held back, so streamed pages still arrive progressively.
///
/// Both snippets are always inserted exactly once, so a known `Content-Length` grows by `addedLength`.
public struct HTMLInjector: Sendable {
    public static let markers: [[UInt8]] = [Array("</head".utf8), Array("<body".utf8)]
    /// Past this much buffered HTML without a marker, stop holding bytes back and append at the end.
    public static let maximumLookahead = 1 << 20

    public let headStart: [UInt8]
    public let headEnd: [UInt8]
    private var buffer: [UInt8] = []
    private var injected = false
    private var givenUp = false

    public init(headStart: String = "", headEnd: String) {
        self.headStart = Array(headStart.utf8)
        self.headEnd = Array(headEnd.utf8)
    }

    public var addedLength: Int { headStart.count + headEnd.count }

    /// Feeds the next chunk; returns the bytes that can be sent on now.
    public mutating func feed(_ chunk: [UInt8]) -> [UInt8] {
        if injected || givenUp { return chunk }
        buffer += chunk
        if let index = Self.firstMarker(in: buffer) {
            injected = true
            defer { buffer = [] }
            let prefix = Array(buffer[..<index])
            var output: [UInt8]
            if let headOpen = Self.endOfHeadTag(in: prefix) {
                output = Array(prefix[..<headOpen]) + headStart + Array(prefix[headOpen...])
            } else {
                output = prefix + headStart
            }
            output += headEnd
            output += buffer[index...]
            return output
        }
        if buffer.count > Self.maximumLookahead {
            givenUp = true
            defer { buffer = [] }
            return buffer
        }
        // Hold everything until a marker shows up, so one split across chunks is still found.
        return []
    }

    /// The end of the response: whatever is held back, plus the snippets if they weren't inserted yet.
    public mutating func finish() -> [UInt8] {
        guard !injected else { return [] }
        injected = true
        defer { buffer = [] }
        return buffer + headStart + headEnd
    }

    static func firstMarker(in bytes: [UInt8]) -> Int? {
        markers.compactMap { index(of: $0, in: bytes) }.min()
    }

    /// The position just after `<head …>` (not `<header>`), if the tag is complete in `bytes`.
    static func endOfHeadTag(in bytes: [UInt8]) -> Int? {
        let needle = Array("<head".utf8)
        var start = 0
        while let found = index(of: needle, in: Array(bytes[start...])).map({ $0 + start }) {
            let after = found + needle.count
            guard after < bytes.count else { return nil }
            let next = bytes[after]
            if next == UInt8(ascii: ">") { return after + 1 }
            if [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(next) {
                return bytes[after...].firstIndex(of: UInt8(ascii: ">")).map { $0 + 1 }
            }
            start = after
        }
        return nil
    }

    /// Case-insensitive (ASCII) search.
    private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var position = 0
        while position <= haystack.count - needle.count {
            if lower(haystack[position]) == first {
                var matched = true
                for offset in 1..<needle.count where lower(haystack[position + offset]) != needle[offset] {
                    matched = false
                    break
                }
                if matched { return position }
            }
            position += 1
        }
        return nil
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}
