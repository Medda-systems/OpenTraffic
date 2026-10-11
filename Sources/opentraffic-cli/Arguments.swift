import Foundation

/// One command's name, what it takes, and its help.
struct CommandSpec: Sendable {
    let name: String
    var aliases: [String] = []
    let group: String
    let usage: String
    let summary: String
    var details: String = ""
    var flags: Set<String> = []
    /// Options that take a value.
    var options: Set<String> = []
    var arguments: ClosedRange<Int> = 0...0
}

/// A parsed command line.
struct Invocation: Equatable {
    var command: String
    var arguments: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    var json: Bool { flags.contains("json") }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    static let globalFlags: Set<String> = ["json", "help", "no-color"]
    static let shortNames: [Character: String] = ["n": "lines", "f": "follow", "o": "output", "y": "yes", "h": "help", "j": "json"]

    /// Parses arguments (without the program name). No arguments lists the shares.
    static func parse(_ raw: [String]) throws -> Invocation {
        guard let first = raw.first else { return Invocation(command: "list") }
        switch first {
        case "-h", "--help": return Invocation(command: "help", arguments: Array(raw.dropFirst().prefix(1)))
        case "-v", "--version": return Invocation(command: "version")
        default: break
        }
        guard let spec = Commands.spec(named: first) else {
            throw CLIError.usage("Unknown command “\(first)”. Run `opentraffic help` for the list.")
        }
        var invocation = Invocation(command: spec.name)
        var tokens = raw.dropFirst()[...]
        var onlyArguments = false
        while let token = tokens.popFirst() {
            if onlyArguments || !token.hasPrefix("-") || token == "-" || Int(token) != nil {
                invocation.arguments.append(token)
                continue
            }
            if token == "--" {
                onlyArguments = true
                continue
            }
            var name: String
            var inlineValue: String?
            if token.hasPrefix("--") {
                name = String(token.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    inlineValue = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
            } else {
                guard token.count == 2, let short = token.last, let long = shortNames[short] else {
                    throw CLIError.usage("Unknown option \(token) for `\(spec.name)`. Run `opentraffic help \(spec.name)`.")
                }
                name = long
            }
            if spec.options.contains(name) {
                guard let value = inlineValue ?? tokens.popFirst() else {
                    throw CLIError.usage("--\(name) needs a value. Run `opentraffic help \(spec.name)`.")
                }
                invocation.options[name] = value
            } else if spec.flags.contains(name) || globalFlags.contains(name) {
                guard inlineValue == nil else { throw CLIError.usage("--\(name) doesn't take a value.") }
                invocation.flags.insert(name)
            } else {
                throw CLIError.usage("Unknown option --\(name) for `\(spec.name)`. Run `opentraffic help \(spec.name)`.")
            }
        }
        if invocation.flags.contains("help") {
            return Invocation(command: "help", arguments: [spec.name])
        }
        guard spec.arguments.contains(invocation.arguments.count) else {
            throw CLIError.usage("Usage: opentraffic \(spec.usage)")
        }
        return invocation
    }
}

/// "on"/"off" and friends.
func parseSwitch(_ value: String, option: String) throws -> Bool {
    switch value.lowercased() {
    case "on", "yes", "true", "1": return true
    case "off", "no", "false", "0": return false
    default: throw CLIError.usage("--\(option) takes on or off.")
    }
}
