import Foundation

/// The rule that keeps a docset offline.
///
/// Turning JavaScript off and refusing non-file *navigations* is not enough: an `<img>`, a
/// stylesheet or a font with an `https://` address is fetched without either. That is a
/// beacon — it tells whoever built the docset when the reader opened which page. These
/// rules are compiled into the web view before any page is loaded, so a docset can only
/// ever read what is already on the reader's disk.
public enum NetworkBlock {
    /// Schemes a page must not be able to reach. `file:` is deliberately absent, and so is
    /// `data:`, which carries its own bytes and goes nowhere.
    public static let blockedSchemes = ["https?", "wss?", "ftps?", "blob"]

    public static var ruleListJSON: String {
        let rules = blockedSchemes.map { scheme in
            """
            {"trigger":{"url-filter":"^\(scheme)://","load-type":["first-party","third-party"]},"action":{"type":"block"}}
            """
        }
        return "[" + rules.joined(separator: ",") + "]"
    }
}
