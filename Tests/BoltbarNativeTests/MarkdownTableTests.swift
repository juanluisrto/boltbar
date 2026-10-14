import XCTest
@testable import BoltbarNative

final class MarkdownTableTests: XCTestCase {
    func testTablesRenderBetweenParagraphsWithoutParsingFencedCode() throws {
        let source = "Before\n\n| City | Average |\n| :--- | ---: |\n| **Madrid** | 15°C |\n| Tokyo | 18°C |\n\nAfter\n```text\n| A | B |\n| - | - |\n```"
        let blocks = MarkdownText.blocks(source)
        let table = try XCTUnwrap(blocks.compactMap(\.table).first)
        XCTAssertEqual(blocks.compactMap(\.table).count, 1)
        XCTAssertEqual(table.headers, ["City", "Average"])
        XCTAssertEqual(table.alignments, [.leading, .trailing])
        XCTAssertEqual(table.rows, [["**Madrid**", "15°C"], ["Tokyo", "18°C"]])
        XCTAssertTrue(blocks.first?.text.contains("Before") == true)
        XCTAssertTrue(blocks.contains { !$0.code && $0.text.contains("After") })
        XCTAssertEqual(blocks.last?.code, true); XCTAssertNil(blocks.last?.table)
    }
    func testEscapedPipesCodeSpansAndRaggedRows() throws {
        let lines = ["Name | Value | Note", ":---: | ---: | ---", #"A\|B | `x|y` | **bold**"#, "C | 2", "D | 3 | kept | extra"]
        let table = try XCTUnwrap(MarkdownTable.parse(lines, at: 0)?.table)
        XCTAssertEqual(table.alignments, [.center, .trailing, .leading])
        XCTAssertEqual(table.rows, [["A|B", "`x|y`", "**bold**"], ["C", "2", ""], ["D", "3", "kept"]])
        XCTAssertEqual(MarkdownTable.cells(#"| ``a`|b`` | \| |"#), ["``a`|b``", "|"])
    }
    func testStreamingTableWaitsForAValidSeparator() {
        XCTAssertNil(MarkdownTable.parse(["| City | Temperature |", "| --- |"], at: 0))
        let partial = MarkdownTable.parse(["| City | Temperature |", "| --- | --- |", "| Madrid | 1"], at: 0)?.table
        XCTAssertEqual(partial?.rows, [["Madrid", "1"]])
        XCTAssertNil(MarkdownTable.parse(["text | pipe", "not | a table"], at: 0))
    }
}
