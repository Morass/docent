import XCTest
@testable import DocentKit

/// The trial verdict was "the text is barely readable against the background", so the
/// palettes are not a matter of taste here: they are checked against WCAG contrast ratios,
/// and a change that dims them fails the suite.
final class ReadingThemeTests: XCTestCase {
    /// WCAG relative luminance.
    private func luminance(_ hex: String) -> Double {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((value >> 16) & 0xff)
             + 0.7152 * channel((value >> 8) & 0xff)
             + 0.0722 * channel(value & 0xff)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let first = luminance(a), second = luminance(b)
        let lighter = max(first, second), darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func testBodyTextPassesTheStrictestContrastLevel() {
        for theme in ReadingTheme.allCases {
            let p = theme.palette
            XCTAssertGreaterThanOrEqual(contrast(p.text, p.background), 7.0,
                                        "\(theme) body text is below WCAG AAA")
        }
    }

    func testSecondaryTextAndLinksAreStillComfortablyReadable() {
        for theme in ReadingTheme.allCases {
            let p = theme.palette
            XCTAssertGreaterThanOrEqual(contrast(p.muted, p.background), 4.5, "\(theme) muted text")
            XCTAssertGreaterThanOrEqual(contrast(p.link, p.background), 4.5, "\(theme) links")
        }
    }

    func testEverySyntaxColourIsReadableOnTheCodeBackground() {
        for theme in ReadingTheme.allCases {
            let p = theme.palette
            for (name, colour) in [("keyword", p.keyword), ("string", p.string), ("comment", p.comment),
                                   ("number", p.number), ("type", p.type), ("code text", p.text)] {
                XCTAssertGreaterThanOrEqual(contrast(colour, p.codeBackground), 4.5,
                                            "\(theme) \(name) is unreadable on code blocks")
            }
        }
    }

    func testTheCodeBlockStaysDistinctFromThePage() {
        for theme in ReadingTheme.allCases {
            let p = theme.palette
            XCTAssertNotEqual(p.codeBackground, p.background, "\(theme): code blocks would vanish into the page")
        }
    }

    func testTheStylesheetDefinesEveryClassTheHighlighterUses() throws {
        let script = try XCTUnwrap(SyntaxHighlight.script)
        for token in ["docent-kw", "docent-str", "docent-com", "docent-num", "docent-type"] {
            XCTAssertTrue(script.contains(token), "the highlighter does not emit \(token)")
            for theme in ReadingTheme.allCases {
                XCTAssertTrue(theme.css.contains(".\(token)"), "\(theme) does not paint \(token)")
            }
        }
    }

    /// The stylesheet reaches the page as a JSON string literal, so nothing in it can close
    /// the literal and become code.
    func testTheStylesheetTravelsAsDataNotSource() throws {
        let script = try XCTUnwrap(ReadingTheme.dark.injectionScript)
        XCTAssertTrue(script.contains("docent-theme"))

        let start = try XCTUnwrap(script.range(of: "var css="))
        let rest = script[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "]"))
        let literal = String(rest[..<end.upperBound])
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String]
        XCTAssertEqual(decoded?.first, ReadingTheme.dark.css, "the CSS did not survive encoding intact")
        XCTAssertFalse(literal.contains("\n\n"), "raw newlines would end the literal")
    }

    func testMatchingFollowsTheSystem() {
        XCTAssertEqual(ReadingTheme.matching(isDark: true), .dark)
        XCTAssertEqual(ReadingTheme.matching(isDark: false), .light)
    }

    func testKeywordsAreUniqueAndSorted() {
        XCTAssertEqual(SyntaxHighlight.keywords, SyntaxHighlight.keywords.sorted())
        XCTAssertEqual(Set(SyntaxHighlight.keywords).count, SyntaxHighlight.keywords.count)
    }
}

extension ReadingThemeTests {
    /// Inline `code` in a sentence must not be tokenised: a word like `private-patterns` is
    /// not a keyword, and colouring it makes prose unreadable.
    func testTheHighlighterOnlyTouchesCodeBlocks() throws {
        let script = try XCTUnwrap(SyntaxHighlight.script)
        XCTAssertFalse(script.contains("querySelectorAll('pre, code')"), "inline code would be highlighted")
        XCTAssertTrue(script.contains("querySelectorAll('pre')"), script.prefix(200).description)
    }

    /// A generated page carries its own typography, because there is no docset stylesheet
    /// behind it — otherwise it renders as full-width serif.
    func testGeneratedPagesCarryTypographyButNoColours() {
        let page = Markdown.render("# T\n\ntext\n", fallbackTitle: "x")
        let html = Markdown.document(page, sourcePath: "x.md")
        XCTAssertTrue(html.contains("font:"), html.prefix(400).description)
        XCTAssertTrue(html.contains("max-width"), "generated pages need a reading measure")
        for colour in ["color:", "background:"] {
            XCTAssertFalse(Markdown.typography.contains(colour + " #"),
                           "typography must not set colours — the reading theme owns those")
        }
    }
}

extension ReadingThemeTests {
    /// The typography is CSS, not Swift: a `///` comment inside that string is not a
    /// comment, it is a parse error that drops the first rule and leaves the page in the
    /// browser's default serif at full width.
    func testTheTypographyIsCSSAndNotSwift() {
        XCTAssertFalse(Markdown.typography.contains("///"), Markdown.typography)
        for line in Markdown.typography.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/") else { continue }
            XCTAssertTrue(trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"),
                          "not a CSS comment: \(trimmed)")
        }
        XCTAssertTrue(Markdown.typography.contains("-apple-system"), "the body font is gone")
    }
}
