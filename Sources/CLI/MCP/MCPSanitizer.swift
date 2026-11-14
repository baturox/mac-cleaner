// Everything that comes from the file system (names, paths, branch names, tool output) is attacker-controlled
// text as far as the model reading it is concerned. It is returned only as quoted JSON string values, after this.
import Foundation

enum MCPSanitizer {
    /// Control characters, bidirectional overrides, line/paragraph separators and zero-width characters are
    /// removed (line breaks and tabs become a space), and the result is capped at `max` characters.
    static func text(_ s: String, max: Int = 200) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F: continue
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFEFF, 0xFFF9...0xFFFB: continue
            default: out.append(u)
            }
        }
        let clean = String(out)
        guard clean.count > max else { return clean }
        return String(clean.prefix(Swift.max(1, max - 1))) + "…"
    }

    static func path(_ s: String) -> String { text(s, max: 500) }
}
