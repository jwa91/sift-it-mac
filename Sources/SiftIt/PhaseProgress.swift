// How far indexing is, as the welcome window and the settings show it: one bar that fills once for each phase, Exact,
// Embeddings, then Transcribed, labelled with the phase at work and its time left, and under it the three phases, each
// done, at work or still to come. The welcome window says what each makes findable; the settings, in a tooltip.

import SiftItKit
import SwiftUI

struct PhaseProgress: View {
    let indexer: IndexerStatus
    /// Each phase with its sentence under it, rather than its name alone.
    var explained = true

    var body: some View {
        let phases = indexer.phases
        let current = phases.first { !$0.isDone }
        VStack(alignment: .leading, spacing: explained ? 14 : 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(current?.phase.name ?? "Up to date").font(.headline)
                    Spacer()
                    if let current, let state = Phases.state(of: current, in: indexer) {
                        Text(state)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: current?.progress ?? 1)
                    .animation(.easeInOut(duration: 0.3), value: current?.phase)
            }
            if explained {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(phases, id: \.phase) { row($0, current: current) }
                }
            } else {
                HStack(spacing: 18) {
                    ForEach(phases, id: \.phase) { row($0, current: current) }
                }
            }
        }
    }

    private func row(_ phase: PhaseStatus, current: PhaseStatus?) -> PhaseRow {
        PhaseRow(
            phase: phase, atWork: phase.phase == current?.phase, paused: indexer.state == .paused,
            explained: explained)
    }
}

/// A phase: done, at work, or still to come, with how far it is when it's under way beside the one at work.
private struct PhaseRow: View {
    let phase: PhaseStatus
    let atWork: Bool
    let paused: Bool
    let explained: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: explained ? 10 : 6) {
            symbol.frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(phase.phase.name)
                        .fontWeight(atWork ? .semibold : .regular)
                        .foregroundStyle(phase.isDone || atWork ? .primary : .secondary)
                    if !atWork, !phase.isDone, phase.started {
                        Text("\(Phases.percent(phase.progress))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if explained {
                    Text(phase.phase.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(explained ? "" : phase.phase.explanation)
    }

    @ViewBuilder private var symbol: some View {
        if phase.isDone {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if atWork {
            Image(systemName: paused ? "pause.circle" : "circle.dotted.circle").foregroundStyle(.tint)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
