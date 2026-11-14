// Grouping, numbering, totals and selection of cleanup categories (shared by scan and clean).
import CleanerCore
import Foundation

enum CategoryListing {
    typealias Section = (group: CategoryGroup, categories: [CleanCategory])

    /// Categories grouped by `CategoryGroup` in display order; the engine's order is kept inside a group.
    static func grouped(_ cats: [CleanCategory]) -> [Section] {
        CategoryGroup.allCases.compactMap { g in
            let inGroup = cats.filter { $0.group == g }
            return inGroup.isEmpty ? nil : (g, inGroup)
        }
    }

    /// Flat list in display order; the 1-based position is the number shown in tables and pickers.
    static func ordered(_ cats: [CleanCategory]) -> [CleanCategory] {
        grouped(cats).flatMap { $0.categories }
    }

    struct Totals: Equatable {
        var exact: Int64 = 0
        var upperBound: Int64 = 0
        var safe: Int64 = 0       // exact sizes only
        var caution: Int64 = 0    // exact sizes only
    }

    static func totals(_ cats: [CleanCategory]) -> Totals {
        var t = Totals()
        for c in cats {
            if c.sizeIsUpperBound {
                t.upperBound += c.sizeBytes
            } else {
                t.exact += c.sizeBytes
                if c.level == .safe { t.safe += c.sizeBytes } else { t.caution += c.sizeBytes }
            }
        }
        return t
    }

    /// Accepts `aiTools`, `ai-tools`, `AI tools`, `ai coding tools`… (case and punctuation insensitive).
    static func parseGroup(_ raw: String) -> CategoryGroup? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let n = norm(raw)
        return CategoryGroup.allCases.first { norm($0.rawValue) == n || norm($0.title) == n }
    }

    /// Resolves what `clean` should act on.
    /// - explicit `ids` are always included (unknown ids are a usage error);
    /// - `safe` / `all` / `group` select by criteria: `safe` keeps safe ones, `all` keeps everything, and
    ///   `group` (alone, or with either) limits the criteria to that group.
    static func select(from cats: [CleanCategory], ids: [String], safe: Bool, all: Bool,
                       group: CategoryGroup?) throws -> [CleanCategory] {
        var chosen = Set<String>()
        for id in ids {
            guard cats.contains(where: { $0.id == id }) else {
                let known = cats.map { $0.id }
                var msg = "no category '\(id)' (it does not exist or has nothing to reclaim)"
                if let best = ArgumentParser.closest(id, among: known) { msg += "; did you mean '\(best)'?" }
                throw UsageError(msg, command: "clean")
            }
            chosen.insert(id)
        }
        if safe || all || group != nil {
            for c in cats {
                if let group, c.group != group { continue }
                if safe && !all && c.level != .safe { continue }
                chosen.insert(c.id)
            }
        }
        return ordered(cats).filter { chosen.contains($0.id) }
    }
}
