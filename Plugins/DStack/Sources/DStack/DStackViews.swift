import SwiftUI

/// The plugin's screen: a card per project with an open run that still has plans left, the most
/// recently active first, in a scroll view when they do not fit. It has no outer padding (the host adds the notch's margin) and
/// fills a wider offer.
struct DStackScreen: View {
    static let width: CGFloat = 360
    let model: DStackModel

    var body: some View {
        let projects = model.screenProjects
        Group {
            if projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("보여 줄 D-STACK 실행이 없어요.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("닫혔거나 계획을 모두 끝낸 실행은 빼요. Claude Code에서 연 프로젝트는 저절로 찾고, 다른 폴더는 설정의 D-STACK에서 더할 수 있어요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let cards = VStack(spacing: 8) {
                    ForEach(projects) { ProjectCard(project: $0, now: model.checkedAt) }
                }
                ViewThatFits(in: .vertical) {
                    cards
                    ScrollView { cards }
                }
            }
        }
        .frame(minWidth: Self.width, idealWidth: Self.width, maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }
}

/// One project: folder name and state, goal title, overall plan bar, task and requirement counts,
/// a thin bar per milestone with plans left (none when every milestone is finished), the plans in
/// progress and the latest activity.
struct ProjectCard: View {
    static let shownPlans = 4
    let project: DStackModel.Project
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch project.reading {
            case .open(let run):
                header(run.startedAt.map { "진행 중 · \(DStackStore.relative($0, now: now)) 시작" } ?? "진행 중")
                details(run)
            case .unsupported(let reason):
                header(nil)
                Text("형식을 읽지 못했어요")
                    .font(.system(size: 13, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .noOpenRun:
                header(nil)
                Text("열린 실행이 없어요")
                    .font(.system(size: 12))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }

    private func header(_ state: String?) -> some View {
        HStack(spacing: 8) {
            Text(project.name)
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            if let state { Text(state) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func details(_ run: RunProgress) -> some View {
        Text(run.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
        HStack(spacing: 8) {
            Text("계획 \(run.plansDone)/\(run.plansTotal)")
            ProgressBar(fraction: run.fraction)
                .frame(height: 5)
            Text("\(Int((run.fraction * 100).rounded()))%")
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        Text("작업 \(run.tasksCommitted)/\(run.tasksTotal) 커밋 · 요구사항 \(run.requirementsMet)/\(run.requirementsCounted) 충족")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        let milestones = run.remainingMilestones
        if !milestones.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(milestones, id: \.id) { milestone in
                    GridRow {
                        Text("\(milestone.id) \(milestone.slug)")
                            .lineLimit(1)
                        ProgressBar(fraction: milestone.total == 0 ? 0 : Double(milestone.done) / Double(milestone.total))
                            .frame(height: 3)
                        Text("\(milestone.done)/\(milestone.total)")
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        if !run.inProgress.isEmpty {
            let more = run.inProgress.count - Self.shownPlans
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("진행 중")
                    .foregroundStyle(.secondary)
                Text(run.inProgress.prefix(Self.shownPlans).map { "\($0.id) \($0.slug)" }.joined(separator: " · ") + (more > 0 ? " +\(more)" : ""))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
        }
        if let latest = run.latest {
            Text("\(DStackStore.relative(latest.date, now: now)) · \(latest.text)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(.green)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
    }
}
