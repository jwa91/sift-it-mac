// The milestones, as the welcome window and the settings show them: each reached, on its way with how far and how
// long, or waiting for what the indexer says.

import SiftItKit
import SwiftUI

struct MilestoneList: View {
    let indexer: IndexerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(indexer.rounds, id: \.round) { round in
                HStack(spacing: 10) {
                    symbol(round)
                        .frame(width: 16, height: 16)
                    Text(Milestones.capitalized(round.round.milestone))
                        .foregroundStyle(round.state == .done ? .primary : .secondary)
                    Spacer()
                    if let state = Milestones.state(of: round, in: indexer) {
                        Text(state)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Reached, at work (turning while nothing is counted yet, so a model that loads doesn't look stuck), waiting, or
    /// still to come.
    @ViewBuilder private func symbol(_ round: RoundStatus) -> some View {
        switch round.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running where indexer.state != .paused:
            if let progress = round.progress, round.done > 0 {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        case .waiting, .running:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
