// Renders captured terminal output (with ANSI colour) as an SVG, for the README.
// Reads the capture on stdin, writes SVG on stdout. Build: swiftc -O term-to-svg.swift
import Foundation

struct Cell {
    var text: String
    var colour: String?
    var bold: Bool
    var dim: Bool
}

let charWidth = 8.42, lineHeight = 19.0, padding = 22.0
let background = "#1d1f26", foreground = "#e6e6ea"

let basic = [
    "#3c3f4c", "#e05a5a", "#5ac27a", "#d8b54a",
    "#5a9ce0", "#b57ae0", "#4ac2c2", "#c9c9d2",
]

func colour(for code: Int) -> String? {
    switch code {
    case 30...37: return basic[code - 30]
    case 90...97: return basic[code - 90]
    case 39: return nil
    default: return nil
    }
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

var input = ""
while let line = readLine(strippingNewline: false) { input += line }

var lines: [[Cell]] = []
for raw in input.split(separator: "\n", omittingEmptySubsequences: false) {
    var cells: [Cell] = []
    var current = Cell(text: "", colour: nil, bold: false, dim: false)
    var index = raw.startIndex

    func push() {
        if !current.text.isEmpty { cells.append(current) }
        current.text = ""
    }

    while index < raw.endIndex {
        if raw[index] == "\u{1B}", raw.index(after: index) < raw.endIndex, raw[raw.index(after: index)] == "[" {
            var cursor = raw.index(index, offsetBy: 2)
            var parameters = ""
            while cursor < raw.endIndex, !raw[cursor].isLetter {
                parameters.append(raw[cursor])
                cursor = raw.index(after: cursor)
            }
            let final = cursor < raw.endIndex ? raw[cursor] : "m"
            if final == "m" {
                push()
                for code in parameters.split(separator: ";").compactMap({ Int($0) }) {
                    switch code {
                    case 0: current = Cell(text: "", colour: nil, bold: false, dim: false)
                    case 1: current.bold = true
                    case 2: current.dim = true
                    case 22: current.bold = false; current.dim = false
                    default: if let found = colour(for: code) { current.colour = found }
                    }
                }
                if parameters.isEmpty { current = Cell(text: "", colour: nil, bold: false, dim: false) }
            }
            index = cursor < raw.endIndex ? raw.index(after: cursor) : raw.endIndex
            continue
        }
        current.text.append(raw[index])
        index = raw.index(after: index)
    }
    push()
    lines.append(cells)
}

// Trim trailing blank lines so a short command does not get a tall picture.
while let last = lines.last, last.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
    lines.removeLast()
}

let columns = lines.map { $0.reduce(0) { $0 + $1.text.count } }.max() ?? 80
let width = Double(columns) * charWidth + padding * 2
let height = Double(lines.count) * lineHeight + padding * 2

var svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width))" height="\(Int(height))" \
viewBox="0 0 \(Int(width)) \(Int(height))" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="13">
<rect width="100%" height="100%" rx="10" fill="\(background)"/>

"""

for (row, cells) in lines.enumerated() {
    var x = padding
    let y = padding + Double(row) * lineHeight + 13
    for cell in cells {
        let text = escape(cell.text)
        var attributes = "x=\"\(String(format: "%.2f", x))\" y=\"\(String(format: "%.2f", y))\" xml:space=\"preserve\""
        attributes += " fill=\"\(cell.colour ?? foreground)\""
        if cell.bold { attributes += " font-weight=\"600\"" }
        if cell.dim { attributes += " opacity=\"0.62\"" }
        svg += "<text \(attributes)>\(text)</text>\n"
        x += Double(cell.text.count) * charWidth
    }
}
svg += "</svg>\n"
print(svg)
