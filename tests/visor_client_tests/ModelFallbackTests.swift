// A turn that ran on another model than the one chosen (Claude falling
// back from a busy or rate-limited model) is told apart from one that ran
// on it, whatever names the two go by.

import VisorProtocol
import XCTest

final class ModelFallbackTests: XCTestCase {
    private let catalog = AgentCatalog(agent: .claude, models: [
        AgentModel(id: "fable", title: "Fable 5.1", efforts: []),
        AgentModel(id: "opus", title: "Opus 5.5", efforts: []),
    ], defaultModel: "opus")

    func testAFallbackIsTheModelThatRan() {
        // Chosen by alias, reported by full name.
        XCTAssertEqual(catalog.fallback(from: "fable", to: "claude-opus-5-5")?.title, "Opus 5.5")
        // The default chosen (nil), another model ran.
        XCTAssertEqual(catalog.fallback(from: nil, to: "claude-fable-5-1")?.title, "Fable 5.1")
    }

    func testTheChosenModelIsNoFallback() {
        XCTAssertNil(catalog.fallback(from: "fable", to: "claude-fable-5-1"))
        XCTAssertNil(catalog.fallback(from: nil, to: "claude-opus-5-5"))
        // Nothing reported yet, or a model this catalog does not know.
        XCTAssertNil(catalog.fallback(from: "fable", to: nil))
        XCTAssertNil(catalog.fallback(from: "fable", to: "some-other-model"))
    }
}
