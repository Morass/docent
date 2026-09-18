import Foundation

/// How a docset's page is painted.
///
/// A docset's CSS was written for a white page in a browser. Shown in a dark window with a
/// transparent background, the same page becomes dark-grey text on near-black — readable in
/// a screenshot, not readable at a desk. So Docent always paints the page itself: white with
/// near-black text, or a dark ground with light text, and enough contrast either way to
/// pass WCAG AAA for body text.
public enum ReadingTheme: String, Sendable, CaseIterable {
    case light
    case dark

    public struct Palette: Sendable {
        public let background: String
        public let text: String
        public let muted: String
        public let link: String
        public let codeBackground: String
        public let codeBorder: String
        public let keyword: String
        public let string: String
        public let comment: String
        public let number: String
        public let type: String
    }

    /// Both palettes are checked by `ReadingThemeTests`: body text is at least 7:1 against
    /// its background, every token colour at least 4.5:1 against the code background.
    public var palette: Palette {
        switch self {
        case .light:
            return Palette(
                background: "#ffffff",
                text: "#14161a",
                muted: "#4a4f57",
                link: "#0b4fd0",
                codeBackground: "#f2f3f6",
                codeBorder: "#d8dade",
                keyword: "#8214a0",
                string: "#0a6b2e",
                comment: "#5a6068",
                number: "#9a4a00",
                type: "#0f5a86"
            )
        case .dark:
            return Palette(
                background: "#16181d",
                text: "#e9eaee",
                muted: "#a9aeb8",
                link: "#7fb0ff",
                codeBackground: "#1e2128",
                codeBorder: "#31353e",
                keyword: "#dda0f0",
                string: "#8fd3a0",
                comment: "#9aa1ab",
                number: "#f0b37a",
                type: "#7fc8ef"
            )
        }
    }

    /// The stylesheet injected into every page. Deliberately narrow: colours, and nothing
    /// about layout — a docset's own spacing, fonts and code formatting are left alone.
    public var css: String {
        let p = palette
        return """
        :root { color-scheme: \(rawValue); }
        html, body { background: \(p.background) !important; color: \(p.text) !important; }
        body * { border-color: \(p.codeBorder) !important; }
        p, li, td, th, dd, dt, span, div, h1, h2, h3, h4, h5, h6, strong, em, b, i {
            color: \(p.text) !important; background-color: transparent !important;
        }
        small, .muted, .subtitle, figcaption { color: \(p.muted) !important; }
        a, a * { color: \(p.link) !important; }
        pre, code, kbd, samp, tt {
            background-color: \(p.codeBackground) !important; color: \(p.text) !important;
        }
        pre { border: 1px solid \(p.codeBorder) !important; }
        hr { border-color: \(p.codeBorder) !important; }
        table, th, td { border-color: \(p.codeBorder) !important; }
        thead th { background-color: \(p.codeBackground) !important; }
        img, svg, video { background: transparent !important; }
        ::selection { background: \(p.link) !important; color: \(p.background) !important; }

        .docent-kw   { color: \(p.keyword) !important; font-weight: 600; }
        .docent-str  { color: \(p.string) !important; }
        .docent-com  { color: \(p.comment) !important; font-style: italic; }
        .docent-num  { color: \(p.number) !important; }
        .docent-type { color: \(p.type) !important; }
        """
    }

    /// JavaScript that installs (or replaces) the stylesheet. The CSS travels as a JSON
    /// string literal, never pasted into the source.
    public var injectionScript: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [css]),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function(){var css=\(literal)[0];
        var id='docent-theme';
        var style=document.getElementById(id);
        if(!style){style=document.createElement('style');style.id=id;
          (document.head||document.documentElement).appendChild(style);}
        style.textContent=css;
        return true;})()
        """
    }

    public static func matching(isDark: Bool) -> ReadingTheme { isDark ? .dark : .light }
}
