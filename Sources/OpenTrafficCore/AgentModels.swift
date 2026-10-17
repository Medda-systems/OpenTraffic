import Foundation

/// A model an agent can be run with: `id` is what its command takes, `name` what people see, `group` the
/// provider it comes from (opencode lists several).
public struct AgentModel: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let group: String?

    public init(id: String, name: String, group: String? = nil) {
        self.id = id
        self.name = name
        self.group = group
    }
}

/// The models an agent offers, and the one it uses when it isn't told (its own setting), if it says.
public struct AgentModelList: Equatable, Sendable {
    public let models: [AgentModel]
    public let defaultModel: String?

    public init(models: [AgentModel], defaultModel: String?) {
        self.models = models
        self.defaultModel = defaultModel
    }

    /// Models by provider, in the order they came.
    public var groups: [(name: String?, models: [AgentModel])] {
        var order: [String?] = []
        var byGroup: [String?: [AgentModel]] = [:]
        for model in models {
            if byGroup[model.group] == nil { order.append(model.group) }
            byGroup[model.group, default: []].append(model)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }
}

/// Finds the models each agent preset can use, from the agent itself: Codex's model catalog, opencode's
/// list of models from the providers it's set up with, Claude Code's aliases (it has no list; they follow
/// the subscription), and nothing for Cursor (it has no way to list them).
public enum AgentModels {
    /// Claude Code's aliases: always the latest model of each kind the subscription offers.
    public static let claudeAliases = [
        AgentModel(id: "fable", name: "Fable"),
        AgentModel(id: "opus", name: "Opus"),
        AgentModel(id: "sonnet", name: "Sonnet"),
        AgentModel(id: "haiku", name: "Haiku"),
    ]

    /// Runs the agent's own commands to find out; `path` is the PATH they're found on. Blocking; call it
    /// off the main thread.
    public static func detect(_ preset: AgentPreset, path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentModelList {
        switch preset {
        case .claudeCode:
            let settings = try? Data(contentsOf: home.appending(path: ".claude/settings.json"))
            return AgentModelList(models: claudeAliases, defaultModel: settings.flatMap(claudeDefault))
        case .codex:
            let catalog = run(path, ["codex", "debug", "models"]).map { codexModels(Data($0.utf8)) } ?? []
            let config = try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
            return AgentModelList(models: catalog, defaultModel: config.flatMap(codexDefault))
        case .opencode:
            let models = run(path, ["opencode", "models"]).map(opencodeModels) ?? []
            let config = run(path, ["opencode", "debug", "config"]).flatMap { opencodeDefault(Data($0.utf8)) }
            return AgentModelList(models: models, defaultModel: config)
        case .cursor, .custom:
            return AgentModelList(models: [], defaultModel: nil)
        }
    }

    private static func run(_ path: String, _ command: [String]) -> String? {
        ToolOutput.run("/usr/bin/env", ["PATH=\(path)"] + command, timeout: 10)
    }

    /// `codex debug models`: the models Codex shows, in its order.
    static func codexModels(_ data: Data) -> [AgentModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return AgentModel(id: slug, name: model["display_name"] as? String ?? slug)
            }
    }

    /// The top-level `model = "…"` of Codex's config.toml (before any [table]).
    static func codexDefault(_ toml: String) -> String? {
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            guard trimmed.hasPrefix("model"), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            let model = String(value[value.index(after: value.startIndex)..<end])
            return model.isEmpty ? nil : model
        }
        return nil
    }

    /// `opencode models`: one `provider/model` per line, grouped by provider.
    static func opencodeModels(_ output: String) -> [AgentModel] {
        output.split(separator: "\n").compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces)
            guard let slash = id.firstIndex(of: "/"), slash != id.startIndex, !id.contains(" ") else { return nil }
            return AgentModel(id: id, name: String(id[id.index(after: slash)...]), group: String(id[..<slash]))
        }
    }

    /// `opencode debug config`: the resolved configuration's `model`.
    static func opencodeDefault(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["model"] as? String
    }

    /// Claude Code's settings.json `model`, if one is set.
    static func claudeDefault(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["model"] as? String
    }
}
