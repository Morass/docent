import Foundation

/// The one line of JavaScript Docent ever runs, and the escaping that makes it safe.
///
/// Page scripts are off in the reader, but the host can still ask the page to scroll to the
/// symbol that was picked — otherwise every result on a long page lands the reader at the
/// top of it. The anchor comes out of a docset, which is third-party data, so it is encoded
/// as a JSON string literal rather than pasted into the source.
public enum AnchorScript {
    public static func scroll(to anchor: String) -> String? {
        guard !anchor.isEmpty else { return nil }
        var spellings = [anchor]
        if let decoded = anchor.removingPercentEncoding, decoded != anchor { spellings.append(decoded) }
        // `//dash_ref_Println/Function/Println/0` also exists as a plain id on the heading.
        for spelling in spellings where spelling.hasPrefix("//") {
            let parts = spelling.split(separator: "/")
            if parts.count > 2 {
                let bare = parts[2].replacingOccurrences(of: "dash_ref_", with: "")
                    .replacingOccurrences(of: "apple_ref_", with: "")
                if !bare.isEmpty, let decoded = bare.removingPercentEncoding { spellings.append(decoded) }
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: spellings),
              let literal = String(data: data, encoding: .utf8) else { return nil }

        return """
        (function(){var names=\(literal);
        for(var i=0;i<names.length;i++){
          var e=document.getElementById(names[i])||document.getElementsByName(names[i])[0];
          if(e){e.scrollIntoView(true);return true;}
        }
        return false;})()
        """
    }
}
