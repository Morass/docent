import Foundation

/// Colouring the code blocks a docset did not colour itself.
///
/// Plenty of docsets ship plain `<pre>` with no markup inside it. This walks those blocks
/// and wraps comments, strings, numbers, keywords and type-looking words in spans that
/// `ReadingTheme` paints. Blocks that already contain markup are left exactly as they are:
/// a docset that highlights its own code knows the language better than this does.
public enum SyntaxHighlight {
    /// Keywords shared across the languages docsets are usually about. Kept deliberately
    /// small and language-agnostic: a wrong colour on an identifier is worse than a missing
    /// colour on a keyword.
    public static let keywords: [String] = [
        "abstract", "and", "as", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "def", "default", "defer", "del", "do", "elif", "else", "end", "enum",
        "extends", "extension", "fallthrough", "false", "final", "finally", "fn", "for", "from",
        "func", "function", "go", "guard", "if", "impl", "import", "in", "init", "interface",
        "internal", "is", "lambda", "let", "map", "match", "mod", "module", "mut", "new", "nil",
        "none", "not", "null", "or", "package", "pass", "private", "protected", "protocol",
        "public", "raise", "range", "return", "self", "static", "struct", "super", "switch",
        "then", "this", "throw", "throws", "trait", "true", "try", "type", "typedef", "union",
        "unsafe", "use", "var", "void", "where", "while", "with", "yield",
    ]

    /// The script is generated rather than written inline so the keyword list has one home
    /// and can be tested.
    public static var script: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: keywords),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function(){
        var KW = new Set(\(literal));
        var blocks = document.querySelectorAll('pre, code');
        var touched = 0;
        function escapeHTML(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
        function highlight(text){
          var out = '';
          var i = 0;
          while (i < text.length) {
            var rest = text.slice(i);
            var m;
            if ((m = rest.match(/^(\\/\\/[^\\n]*|#[^\\n]*|--[^\\n]*)/))) {
              out += '<span class="docent-com">' + escapeHTML(m[0]) + '</span>'; i += m[0].length; continue;
            }
            if ((m = rest.match(/^\\/\\*[\\s\\S]*?\\*\\//))) {
              out += '<span class="docent-com">' + escapeHTML(m[0]) + '</span>'; i += m[0].length; continue;
            }
            if ((m = rest.match(/^("(?:[^"\\\\\\n]|\\\\.)*"|'(?:[^'\\\\\\n]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`)/))) {
              out += '<span class="docent-str">' + escapeHTML(m[0]) + '</span>'; i += m[0].length; continue;
            }
            if ((m = rest.match(/^(0[xX][0-9a-fA-F]+|\\d+\\.?\\d*(?:[eE][-+]?\\d+)?)/))) {
              out += '<span class="docent-num">' + escapeHTML(m[0]) + '</span>'; i += m[0].length; continue;
            }
            if ((m = rest.match(/^[A-Za-z_][A-Za-z0-9_]*/))) {
              var word = m[0];
              if (KW.has(word)) { out += '<span class="docent-kw">' + escapeHTML(word) + '</span>'; }
              else if (/^[A-Z][A-Za-z0-9_]*$/.test(word)) { out += '<span class="docent-type">' + escapeHTML(word) + '</span>'; }
              else { out += escapeHTML(word); }
              i += word.length; continue;
            }
            out += escapeHTML(text[i]); i += 1;
          }
          return out;
        }
        for (var b = 0; b < blocks.length; b++) {
          var block = blocks[b];
          if (block.closest('pre') !== block && block.tagName === 'CODE' && block.closest('pre')) continue;
          if (block.children.length > 0) continue;            // already marked up: leave it alone
          if (block.dataset.docentHighlighted === '1') continue;
          var text = block.textContent;
          if (!text || text.length > 100000) continue;
          block.innerHTML = highlight(text);
          block.dataset.docentHighlighted = '1';
          touched += 1;
        }
        return touched;})()
        """
    }
}
