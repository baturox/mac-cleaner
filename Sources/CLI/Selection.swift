// Parsing of picker input such as "1,3-5" and the interactive pickers built on it.
import CleanerCore
import Foundation

enum SelectionError: Error, Equatable {
    case invalid(String)
    case outOfRange(Int, max: Int)

    var message: String {
        switch self {
        case .invalid(let s): return "cannot understand '\(s)'"
        case .outOfRange(let n, let max): return "\(n) is out of range (1-\(max))"
        }
    }
}

/// Parses "1,3-5" (commas or spaces) into sorted unique 1-based numbers within 1...max.
func parseSelection(_ input: String, max: Int) throws -> [Int] {
    var result = Set<Int>()
    let tokens = input.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
    for raw in tokens {
        let token = String(raw)
        if let dash = token.firstIndex(of: "-"), dash != token.startIndex {
            guard let lo = Int(token[..<dash]), let hi = Int(token[token.index(after: dash)...]) else {
                throw SelectionError.invalid(token)
            }
            guard lo <= hi else { throw SelectionError.invalid(token) }
            for n in [lo, hi] where n < 1 || n > max { throw SelectionError.outOfRange(n, max: max) }
            for n in lo...hi { result.insert(n) }
        } else {
            guard let n = Int(token) else { throw SelectionError.invalid(token) }
            guard n >= 1, n <= max else { throw SelectionError.outOfRange(n, max: max) }
            result.insert(n)
        }
    }
    return result.sorted()
}

/// Asks until the answer parses. Returns nil when the user cancels (empty line, `q`, or end of input).
/// `shortcuts` maps a word ("a", "s") to the numbers it stands for.
func promptSelection(_ ctx: Context, prompt: String, max: Int, shortcuts: [String: [Int]] = [:]) -> [Int]? {
    while true {
        ctx.console.errRaw(prompt)
        guard let line = ctx.console.readLine() else { return nil }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        if answer.isEmpty || answer == "q" || answer == "quit" { return nil }
        if let preset = shortcuts[answer] { return preset }
        do {
            let picked = try parseSelection(answer, max: max)
            if picked.isEmpty { return nil }
            return picked
        } catch let e as SelectionError {
            ctx.err(ctx.style.red("  \(e.message)"))
        } catch {
            return nil
        }
    }
}
