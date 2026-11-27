// A row's preview shows a message's markdown rendered: each construct by
// its words, none of its marks; styled where a line can be (bold, italic,
// code), stripped where a two-line preview can't show it (headings, lists,
// quotes, fences, rules). A marker nothing closes stays as written.

@testable import VisorUI
import XCTest

final class PreviewMarkdownTests: XCTestCase {
    private func plain(_ markdown: String) -> String { PreviewMarkdown.plain(markdown) }

    func testInlineMarksGoTheirWordsStay() {
        XCTAssertEqual(plain("Make it **bold** and *slanted* and _so_."), "Make it bold and slanted and so.")
        XCTAssertEqual(plain("Ran `swift test` and ``a ` b``."), "Ran swift test and a ` b.")
        XCTAssertEqual(plain("See [the PR](https://github.com/x/y/pull/1) and ![a chart](chart.png)."), "See the PR and a chart.")
        XCTAssertEqual(plain("~~Gone~~ and __strong__ and \\*literal\\*."), "Gone and strong and *literal*.")
        XCTAssertEqual(plain("A **[bold link](u)**."), "A bold link.")
    }

    func testTheStylesAreKept() {
        XCTAssertEqual(PreviewMarkdown.spans("a **b** *c* `d`"), [
            .init(text: "a "), .init(text: "b", bold: true), .init(text: " "), .init(text: "c", italic: true), .init(text: " "),
            .init(text: "d", code: true),
        ])
    }

    func testBlocksAreStrippedToTheirWords() {
        XCTAssertEqual(plain("## Results\nAll green."), "Results\nAll green.")
        XCTAssertEqual(plain("# Title #"), "Title")
        XCTAssertEqual(plain("- one\n* two\n+ three\n1. four\n2) five"), "one\ntwo\nthree\nfour\nfive")
        XCTAssertEqual(plain("- [x] done\n- [ ] not yet"), "done\nnot yet")
        XCTAssertEqual(plain("> quoted\n> > deeper"), "quoted\ndeeper")
        XCTAssertEqual(plain("Before\n```swift\nlet a = 1\n```\nAfter"), "Before\nlet a = 1\nAfter")
        XCTAssertEqual(plain("Above\n\n---\n\nBelow"), "Above\nBelow")
        XCTAssertEqual(PreviewMarkdown.spans("```\nlet a = 1\n```"), [.init(text: "let a = 1", code: true)])
    }

    func testWhatIsNotMarkdownStays() {
        XCTAssertEqual(plain("snake_case_name and a_b"), "snake_case_name and a_b")
        XCTAssertEqual(plain("2 * 3 = 6, and 4*5"), "2 * 3 = 6, and 4*5")
        XCTAssertEqual(plain("**unclosed and `open"), "**unclosed and `open")
        XCTAssertEqual(plain("# C#"), "C#")
        XCTAssertEqual(plain("#hashtag and -dash"), "#hashtag and -dash")
        XCTAssertEqual(plain("Plain words."), "Plain words.")
        XCTAssertEqual(plain("[not a link] (x)"), "[not a link] (x)")
    }
}
