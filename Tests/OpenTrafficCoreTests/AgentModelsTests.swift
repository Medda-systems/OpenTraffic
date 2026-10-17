import Foundation
import Testing
@testable import OpenTrafficCore

// The models each agent offers, from the agent itself, and the model picked in Settings reaching the run.

@Test func codexListsTheModelsItShowsInItsOrder() {
    let catalog = #"{"models":[{"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","priority":3},{"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide","priority":4},{"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list","priority":1}]}"#
    #expect(AgentModels.codexModels(Data(catalog.utf8)) == [
        AgentModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol"),
        AgentModel(id: "gpt-6-sol", name: "GPT-6-Sol"),
    ])
    #expect(AgentModels.codexModels(Data("not json".utf8)).isEmpty)
}

@Test func codexsDefaultIsItsTopLevelModel() {
    #expect(AgentModels.codexDefault("model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"medium\"\n") == "gpt-6.1-sol")
    #expect(AgentModels.codexDefault("# mine\nmodel='gpt-6-luna'") == "gpt-6-luna")
    // A profile's model isn't the default.
    #expect(AgentModels.codexDefault("[profiles.fast]\nmodel = \"gpt-6-luna\"") == nil)
    #expect(AgentModels.codexDefault("model_provider = \"x\"") == nil)
}

@Test func opencodeListsModelsByProvider() {
    let list = AgentModelList(models: AgentModels.opencodeModels("opencode/big-pickle\nopenai/gpt-6-sol\nopencode/beam-free\n\nnot a model\nnetlight/claude-opus-5-5\n"), defaultModel: nil)
    #expect(list.models.map(\.id) == ["opencode/big-pickle", "openai/gpt-6-sol", "opencode/beam-free", "netlight/claude-opus-5-5"])
    #expect(list.models.first?.name == "big-pickle")
    #expect(list.groups.map(\.name) == ["opencode", "openai", "netlight"])
    #expect(list.groups.first?.models.map(\.id) == ["opencode/big-pickle", "opencode/beam-free"])
    #expect(AgentModels.opencodeDefault(Data(#"{"model":"netlight/claude-opus-5-5","provider":{}}"#.utf8)) == "netlight/claude-opus-5-5")
}

@Test func claudeCodeOffersItsAliasesAndCursorNothing() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "ot-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try #"{"model":"opus"}"#.write(to: home.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
    let claude = AgentModels.detect(.claudeCode, path: "/nonexistent", home: home)
    #expect(claude.models.map(\.id) == ["fable", "opus", "sonnet", "haiku"])
    #expect(claude.defaultModel == "opus")
    #expect(AgentModels.detect(.cursor, path: "/nonexistent", home: home).models.isEmpty)
}

extension ProcessSpawningTests {
// An agent that isn't installed offers nothing, rather than failing.
@Test func anAgentThatIsntThereOffersNoModels() {
    let empty = FileManager.default.temporaryDirectory.appending(path: "ot-home-\(UUID().uuidString)")
    #expect(AgentModels.detect(.codex, path: "/nonexistent", home: empty) == AgentModelList(models: [], defaultModel: nil))
    #expect(AgentModels.detect(.opencode, path: "/nonexistent", home: empty).models.isEmpty)
}
}
