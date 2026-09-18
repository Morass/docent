import Foundation

/// Text that came out of a docset, made safe to print.
///
/// Symbol names, types and page text are third-party data. A name holding `ESC[2J` clears
/// the reader's screen; one holding `ESC]0;…BEL` retitles their window. Colour is something
/// Docent adds *after* this, never something the data can ask for.
public enum SafeText {
    /// Strips the control characters that a terminal acts on, keeping tabs and newlines.
    public static func terminal(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:                 // tab, newline
                out.append(scalar)
            case 0x00...0x1F, 0x7F:          // the rest of C0, and DEL
                continue
            case 0x80...0x9F:                // C1, which some terminals also act on
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}
