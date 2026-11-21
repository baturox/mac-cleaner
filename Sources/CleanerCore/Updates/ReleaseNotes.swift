// Turns a release body (untrusted text from the network) into a few plain lines for display.
//
// Only a small part of Markdown is understood: headings, bullets, quotes, `[text](url)` links, and the markers
// for bold, italic and code, which are dropped. Everything else, HTML included, is shown as the plain text it is.
// A link is kept only when it is https and points at github.com; any other link shows its text without the link.
import Foundation

public struct ReleaseNotesRun: Equatable, Sendable {
    public var text: String
    public var link: URL?
    public init(_ text: String, link: URL? = nil) { self.text = text; self.link = link }
}

public struct ReleaseNotesLine: Equatable, Sendable {
    public enum Kind: Sendable { case heading, bullet, paragraph, blank }
    public var kind: Kind
    public var runs: [ReleaseNotesRun]
    public var plain: String { runs.map(\.text).joined() }
}

public enum ReleaseNotes {
    public static let maxLines = 200
    public static let maxLineLength = 400

    public static func render(_ body: String) -> [ReleaseNotesLine] {
        var lines: [ReleaseNotesLine] = []
        var previousBlank = true
        var inFence = false
        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard lines.count < maxLines else { break }
            var line = sanitize(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                lines.append(ReleaseNotesLine(kind: .paragraph, runs: [ReleaseNotesRun("    " + line)]))
                previousBlank = false
                continue
            }
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty || line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == "=" }) && line.count >= 3 {
                if !previousBlank { lines.append(ReleaseNotesLine(kind: .blank, runs: [])) }
                previousBlank = true
                continue
            }
            previousBlank = false
            var kind = ReleaseNotesLine.Kind.paragraph
            if line.hasPrefix("#") {
                kind = .heading
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            } else if let first = line.first, first == "-" || first == "*" || first == "+", line.dropFirst().first == " " {
                kind = .bullet
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if line.count > maxLineLength { line = String(line.prefix(maxLineLength)) + "…" }
            lines.append(ReleaseNotesLine(kind: kind, runs: runs(in: line)))
        }
        while lines.last?.kind == .blank { lines.removeLast() }
        return lines
    }

    /// Drops control characters and the invisible and direction-changing characters that can make text lie.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                if u == "\t" { out.append(" ") }
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Splits one line into text and link runs, and drops emphasis markers.
    static func runs(in line: String) -> [ReleaseNotesRun] {
        var runs: [ReleaseNotesRun] = []
        var buffer = ""
        func flush() { if !buffer.isEmpty { runs.append(ReleaseNotesRun(stripMarkers(buffer))); buffer = "" } }
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "!" && i + 1 < chars.count && chars[i + 1] == "[" { i += 1; continue }   // image: show its alt text
            if c == "[", let close = chars[(i + 1)...].firstIndex(of: "]"),
               close + 1 < chars.count, chars[close + 1] == "(",
               let end = chars[(close + 2)...].firstIndex(of: ")") {
                let label = stripMarkers(String(chars[(i + 1)..<close]))
                let target = String(chars[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
                flush()
                if let url = URL(string: target), UpdateHostPolicy.isSafeLink(url), !label.isEmpty {
                    runs.append(ReleaseNotesRun(label, link: url))
                } else if !label.isEmpty {
                    runs.append(ReleaseNotesRun(label))
                }
                i = end + 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return runs
    }

    private static func stripMarkers(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
    }
}
