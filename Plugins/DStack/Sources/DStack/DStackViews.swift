import AppKit
import NotchKit
import SwiftUI

/// The plugin's screen: a card per project with an open run, the most recently active first, in a
/// scroll view when they do not fit. It has no outer padding (the host adds the notch's margin) and
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
                    Text("Claude Code에서 연 프로젝트는 저절로 찾아요. 다른 폴더는 설정의 D-STACK에서 더해 주세요.")
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
/// a thin bar per milestone, the plans in progress and the latest activity.
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
        Text("작업 \(run.tasksCommitted)/\(run.tasksTotal) 커밋 · 요구사항 \(run.requirementsMet)/\(run.requirementsLive) 충족")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        if !run.milestones.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(run.milestones, id: \.id) { milestone in
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

/// The home tile: the most recently active open run, else a store this plugin cannot read, else a
/// note that there is none. Wide: goal title, the plans bar with done/total, a strip with a segment
/// per milestone, task and requirement counts with the plans in progress, and the latest activity.
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
                VStack(alignment: .leading, spacing: 3) {
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
                    MilestoneStrip(milestones: run.milestones)
                        .frame(height: 3)
                    HStack(spacing: 6) {
                        Text("작업 \(run.tasksCommitted)/\(run.tasksTotal) · 요구사항 \(run.requirementsMet)/\(run.requirementsLive)")
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
                    Text("열린 D-STACK 실행이 없어요")
                        .font(.system(size: 11, weight: .semibold))
                    Text("설정에서 폴더를 더할 수 있어요")
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

/// One segment per milestone, each filled by its share of done plans.
struct MilestoneStrip: View {
    let milestones: [MilestoneProgress]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(milestones, id: \.id) { milestone in
                ProgressBar(fraction: milestone.total == 0 ? 0 : Double(milestone.done) / Double(milestone.total))
            }
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

/// Settings: every project found or added, with its state and a button to remove it, and a folder
/// picker to add one.
struct DStackSettingsView: View {
    let model: DStackModel

    var body: some View {
        LabeledContent {
            Button("폴더 추가…") { chooseFolder() }
        } label: {
            Text("D-STACK 프로젝트")
            Text("Claude Code에서 연 프로젝트 가운데 D-STACK을 쓰는 곳은 저절로 찾아요. 다른 폴더는 직접 더하고, 보고 싶지 않은 프로젝트는 뺄 수 있어요. 뺀 폴더는 폴더 추가로 다시 넣어요.")
        }
        .onAppear { Task { await model.refresh() } }
        ForEach(model.projects) { project in
            LabeledContent {
                Button("빼기") { Task { await model.remove(project.url) } }
            } label: {
                Text(project.name)
                Text("\((project.url.path as NSString).abbreviatingWithTildeInPath) · \(state(project))")
            }
        }
    }

    private func state(_ project: DStackModel.Project) -> String {
        switch project.reading {
        case .open(let run): "열린 실행: \(run.title)"
        case .unsupported(let reason): "형식을 읽지 못했어요 · \(reason)"
        case .noOpenRun: project.hasStore ? "열린 실행이 없어요" : "D-STACK 저장소가 없어요"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "추가"
        panel.message = "D-STACK을 쓰는 프로젝트 폴더를 골라 주세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.add(url) }
    }
}
