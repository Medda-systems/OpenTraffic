import CoreImage
import Foundation

/// How things look in the terminal: color only on a terminal, and never with NO_COLOR set.
struct Style: Sendable {
    let color: Bool

    static let current = Style(color: isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        && ProcessInfo.processInfo.environment["TERM"] != "dumb")

    func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func bold(_ text: String) -> String { paint(text, "1") }
    func dim(_ text: String) -> String { paint(text, "2") }
    func green(_ text: String) -> String { paint(text, "32") }
    func red(_ text: String) -> String { paint(text, "31") }
    func yellow(_ text: String) -> String { paint(text, "33") }
    func cyan(_ text: String) -> String { paint(text, "36") }
}

enum Format {
    /// "live", "starting", … in a color for its state.
    static func state(_ state: String, style: Style = .current) -> String {
        switch state {
        case "running": style.green("● live")
        case "starting": style.yellow("◐ starting")
        case "stopping": style.yellow("◑ stopping")
        case "failed": style.red("✕ failed")
        default: style.dim("○ stopped")
        }
    }

    /// The way of sharing, as the app names it.
    static func via(_ share: Share) -> String {
        switch share.kind {
        case "quick": "Temporary URL"
        case "remote": "Your domain"
        case "opentunnel": "OpenTunnel"
        case "tailscale": share.funnel == true ? "Tailscale Funnel" : "Tailnet"
        case "ngrok": "ngrok"
        default: share.provider
        }
    }

    /// Who can open the link.
    static func audience(_ share: Share) -> String {
        switch share.protection {
        case "password": "password"
        case "google": "Google sign-in"
        case "github": "GitHub sign-in"
        case "email": "email codes"
        default: share.kind == "tailscale" && share.funnel != true ? "your tailnet" : "anyone with the link"
        }
    }

    /// `http://localhost:5173` as `:5173`, other addresses as they are.
    static func local(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path.isEmpty || components.path == "/" ? "" : components.path
        return isLocal ? "\(port)\(path)" : "\(host)\(port)\(path)"
    }

    /// "just now", "12 min", "3 h", "2 days".
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86400: return "\(Int(seconds / 3600)) h"
        default:
            let days = Int(seconds / 86400)
            return days == 1 ? "1 day" : "\(days) days"
        }
    }

    /// "just now", "12 min ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let age = age(since: date, now: now)
        return age == "just now" ? age : "\(age) ago"
    }

    /// "in 42 min".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 60 else { return "in under a minute" }
        return seconds < 3600 ? "in \(Int(seconds / 60)) min" : "in \(Int(seconds / 3600)) h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min"
    }

    static func plural(_ count: Int, _ word: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? word : plural ?? word + "s")"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

/// Columns padded to their widest cell, ignoring color codes.
struct Table {
    var header: [String]
    var rows: [[String]] = []

    func render(style: Style = .current) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { Self.visibleWidth($0[safe: column] ?? "") }.max() ?? 0 }
        func line(_ cells: [String], header: Bool = false) -> String {
            cells.enumerated().map { index, cell in
                let padded = index == cells.count - 1 ? cell : cell + String(repeating: " ", count: max(0, widths[index] - Self.visibleWidth(cell)))
                return header ? style.dim(padded) : padded
            }
            .joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        return ([line(header, header: true)] + rows.map { line($0) }).joined(separator: "\n")
    }

    static func visibleWidth(_ text: String) -> Int {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum QRCode {
    /// The code as lines of half blocks, two modules per character, with a quiet zone, light on dark
    /// or dark on light so phone cameras read it in either terminal theme.
    static func lines(for text: String) -> [String]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8, colorSpace: nil)
        let quiet = 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let x = x - quiet, y = y - quiet
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return pixels[y * width + x] < 128
        }
        let size = (width + quiet * 2, height + quiet * 2)
        var lines: [String] = []
        for y in stride(from: 0, to: size.1, by: 2) {
            var line = ""
            for x in 0..<size.0 {
                // Light modules drawn as blocks: works on dark terminals; inverted where the theme is light.
                switch (dark(x, y), y + 1 < size.1 ? dark(x, y + 1) : false) {
                case (false, false): line += "█"
                case (false, true): line += "▀"
                case (true, false): line += "▄"
                case (true, true): line += " "
                }
            }
            lines.append(line)
        }
        return lines
    }
}
