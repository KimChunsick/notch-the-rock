import NotchKit
import SwiftUI

/// The home tile: the most recently active open run with plans left, else a store this plugin cannot
/// read, else a note that there is no run to show (finished runs are left out, or another folder can
/// be added). Wide: goal title, the plans bar with done/total, a strip
/// with a labeled segment per milestone with plans left, task and requirement counts with the plans
/// in progress, and the latest activity.
/// Small: a ring with the percentage, the project name, the first plan in progress and the tasks.
struct DStackTile: View {
    static let shownPlans = 3
    let model: DStackModel
    let size: TileSize

    var body: some View {
        let project = model.tileProject
        Group {
            switch (project?.reading, size) {
            case (.open(let run), .small):
                VStack(spacing: 3) {
                    ring(run.fraction, "\(Int((run.fraction * 100).rounded()))%")
                    Text(project?.name ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                    Text(([run.inProgress.first?.id] + ["작업 \(run.tasksCommitted)/\(run.tasksTotal)"]).compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 70)
            case (.open(let run), _):
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProgressBar(fraction: run.fraction)
                            .frame(height: 5)
                        Text("계획 \(run.plansDone)/\(run.plansTotal)")
                            .font(.system(size: 9, weight: .medium))
                            .fixedSize()
                    }
                    if !run.remainingMilestones.isEmpty {
                        MilestoneStrip(milestones: run.remainingMilestones)
                    }
                    HStack(spacing: 6) {
                        Text("작업 \(run.tasksCommitted)/\(run.tasksTotal) · 요구사항 \(run.requirementsMet)/\(run.requirementsCounted)")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Spacer(minLength: 0)
                        Text(plans(run))
                            .lineLimit(1)
                    }
                    .font(.system(size: 9))
                    Text(run.latest.map { "\(DStackStore.relative($0.date, now: model.checkedAt)) · \($0.text)" } ?? " ")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .monospacedDigit()
                .frame(width: 170, alignment: .leading)
            case (.unsupported(let reason), .small):
                VStack(spacing: 3) {
                    Text("형식을 읽지 못했어요")
                        .font(.system(size: 9, weight: .semibold))
                    Text(reason)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(project?.name ?? "")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 70)
            case (.unsupported(let reason), _):
                VStack(alignment: .leading, spacing: 3) {
                    Text("형식을 읽지 못했어요")
                        .font(.system(size: 11, weight: .semibold))
                    Text(reason)
                        .font(.system(size: 10))
                        .lineLimit(2)
                    Text(project?.name ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            case (_, .small):
                VStack(spacing: 5) {
                    ring(0, "–")
                    Text("D-STACK")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 70)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Text("보여 줄 D-STACK 실행이 없어요")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.hasFinishedRun ? "계획을 모두 끝낸 실행은 빼요" : "설정에서 폴더를 더할 수 있어요")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            }
        }
        .padding(10)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    private func ring(_ fraction: Double, _ label: String) -> some View {
        ZStack {
            ProgressRing(fraction: fraction)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 38, height: 38)
    }

    private func plans(_ run: RunProgress) -> String {
        let more = run.inProgress.count - Self.shownPlans
        return run.inProgress.prefix(Self.shownPlans).map(\.id).joined(separator: " ") + (more > 0 ? " +\(more)" : "")
    }
}

/// One segment per milestone, all as wide: its id and done/total plans, e.g. `M1 5/5`, above a bar
/// filled by its share of done plans. A label longer than its segment shrinks a little first.
struct MilestoneStrip: View {
    let milestones: [MilestoneProgress]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(milestones, id: \.id) { milestone in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(milestone.id) \(milestone.done)/\(milestone.total)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    ProgressBar(fraction: milestone.total == 0 ? 0 : Double(milestone.done) / Double(milestone.total))
                        .frame(height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
    }
}
