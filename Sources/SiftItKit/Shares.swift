// Parts of a whole, as a grid of cells shows them and as a share: Settings → Index's embeddings by kind.

import Foundation

public enum Shares {
    /// The cells each part fills of `cells`, in the parts' order: each its share rounded down, and the cells left over
    /// to the largest remainders, so they add up. A part too small for half a cell may get none.
    public static func cells(_ counts: [Int], of cells: Int) -> [Int] {
        let whole = counts.reduce(0, +)
        guard whole > 0, cells > 0 else { return counts.map { _ in 0 } }
        let exact = counts.map { Double($0) * Double(cells) / Double(whole) }
        var given = exact.map { Int($0) }
        let left = cells - given.reduce(0, +)
        let remainder = exact.indices.map { exact[$0] - Double(given[$0]) }
        let largest = exact.indices.sorted { remainder[$0] != remainder[$1] ? remainder[$0] > remainder[$1] : $0 < $1 }
        for part in largest.prefix(left) { given[part] += 1 }
        return given
    }

    /// A part's share of the whole: "45%", and "<1%" for one that isn't nothing.
    public static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0, part > 0 else { return "0%" }
        let percent = Int((Double(part) * 100 / Double(whole)).rounded())
        return percent == 0 ? "<1%" : "\(percent)%"
    }
}
