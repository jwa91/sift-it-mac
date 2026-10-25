// The index's embeddings by the kind of file they're from, for Settings → Index: a grid of a hundred cells, each one
// percent, in the colour of its kind, and while Embeddings is at work, the part still to embed left empty. A legend
// says each kind's embeddings and its cells, so no colour has to be told apart on its own.

import SiftItKit
import SwiftUI

struct EmbeddingsByKind: View {
    /// The embeddings of each kind, by its name.
    let vectors: [String: Int]
    /// How far Embeddings is, from 0 to 1.
    let progress: Double

    private static let cells = 100
    private static let columns = 25

    private struct Part: Identifiable {
        let kind: Kind
        let count: Int
        var id: String { kind.rawValue }
    }

    var body: some View {
        let parts = self.parts
        let total = parts.reduce(0) { $0 + $1.count }
        let filled = total > 0 ? Int((min(max(progress, 0), 1) * Double(Self.cells)).rounded()) : 0
        let shares = Shares.cells(parts.map(\.count), of: filled)
        let grid: [Part?] =
            zip(parts, shares).flatMap { Array(repeating: $0, count: $1) }
            + Array(repeating: nil, count: Self.cells - filled)
        VStack(alignment: .leading, spacing: 14) {
            if total == 0 {
                Text("No embeddings yet").foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: Self.columns), spacing: 3
            ) {
                ForEach(grid.indices, id: \.self) { index in
                    cell(grid[index], total: total)
                }
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], alignment: .leading, spacing: 6
            ) {
                ForEach(Array(zip(parts, shares)), id: \.0.id) { part, cells in
                    entry(Swatch(kind: part.kind), Format.kindsName(part.kind), count: part.count.formatted()) {
                        cells > 0 ? "\(cells)%" : "<1%"
                    }
                }
                if filled < Self.cells, total > 0 {
                    entry(Swatch(kind: nil), "Still to embed", count: "") { "\(Self.cells - filled)%" }
                }
            }
            .font(.callout)
        }
    }

    /// The kinds with embeddings, in Kind.all's order (each keeps its colour), then any other the engine names.
    private var parts: [Part] {
        let known = Kind.all.map(\.rawValue)
        let kinds = Kind.all + vectors.keys.filter { !known.contains($0) }.sorted().map(Kind.init(rawValue:))
        return kinds.compactMap { kind in
            vectors[kind.rawValue].flatMap { $0 > 0 ? Part(kind: kind, count: $0) : nil }
        }
    }

    private func cell(_ part: Part?, total: Int) -> some View {
        Swatch(kind: part?.kind, corner: 3)
            .aspectRatio(1, contentMode: .fit)
            .help(
                part.map {
                    "\(Format.kindsName($0.kind)): \($0.count.formatted()) embeddings, "
                        + Shares.percent($0.count, of: total) + " of them"
                } ?? "Still to embed")
    }

    private func entry(
        _ swatch: Swatch, _ name: String, count: String, share: () -> String
    ) -> some View {
        HStack(spacing: 7) {
            swatch.frame(width: 10, height: 10)
            Text(name)
            Spacer(minLength: 6)
            Text(count).foregroundStyle(.secondary)
            Text(share()).frame(minWidth: 34, alignment: .trailing)
        }
        .monospacedDigit()
    }
}

/// A kind's colour, filled; without a kind, an empty cell.
private struct Swatch: View {
    let kind: Kind?
    var corner: CGFloat = 2

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if let kind {
            shape.fill(Self.colour(of: kind))
        } else {
            shape.strokeBorder(.tertiary, lineWidth: 1)
        }
    }

    /// The kinds' colours, in Kind.all's order, each with a step for light and one for dark: a categorical
    /// palette whose neighbours stay apart for colour-blind eyes too.
    private static let colours: [Kind: (light: UInt32, dark: UInt32)] = [
        .document: (0x2a78d6, 0x3987e5), .plaintext: (0xeb6834, 0xd95926), .image: (0x1baf7a, 0x199e70),
        .screenshot: (0xeda100, 0xc98500), .audio: (0xe87ba4, 0xd55181), .video: (0x008300, 0x008300),
        .code: (0x6250d6, 0x9085e9), .structured: (0xe34948, 0xe66767),
        // A ninth kind takes the neutral grey a ninth series gets: eight hues are all that stay apart.
        .conversation: (0x7d7d78, 0x9a9a95),
    ]

    static func colour(of kind: Kind) -> Color {
        guard let (light, dark) = colours[kind] else { return .gray }
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
            })
    }
}
