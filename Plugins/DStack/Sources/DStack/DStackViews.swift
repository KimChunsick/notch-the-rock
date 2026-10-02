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
            case .unsupported(let version):
                header(nil)
                Text(version.map { "지원하지 않는 형식이에요 (버전 \($0))" } ?? "지원하지 않는 형식이에요")
                    .font(.system(size: 12))
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

/// The home tile for the most recently active open run. Wide: goal title, overall bar and the plans
/// in progress. Small: a ring with the percentage and the project name.
struct DStackTile: View {
    let model: DStackModel
    let size: TileSize

    var body: some View {
        let project = model.screenProjects.first { if case .open = $0.reading { true } else { false } }
        let run: RunProgress? = if case .open(let run) = project?.reading { run } else { nil }
        Group {
            switch size {
            case .small:
                VStack(spacing: 5) {
                    ZStack {
                        ProgressRing(fraction: run?.fraction ?? 0)
                        Text(run.map { "\(Int(($0.fraction * 100).rounded()))%" } ?? "–")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 46, height: 46)
                    Text(project?.name ?? "D-STACK")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 70)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text(run?.title ?? "열린 D-STACK 실행이 없어요")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProgressBar(fraction: run?.fraction ?? 0)
                            .frame(height: 5)
                        Text(run.map { "\($0.plansDone)/\($0.plansTotal)" } ?? "–")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                    }
                    Text(plansLine(run) ?? project?.name ?? "설정에서 폴더를 더할 수 있어요")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 170, alignment: .leading)
            }
        }
        .padding(10)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    private func plansLine(_ run: RunProgress?) -> String? {
        guard let run, !run.inProgress.isEmpty else { return nil }
        let more = run.inProgress.count - 3
        return "진행 중 " + run.inProgress.prefix(3).map(\.id).joined(separator: " · ") + (more > 0 ? " +\(more)" : "")
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
                .stroke(.white.opacity(0.15), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2.5)
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
        .onAppear { model.refresh() }
        ForEach(model.projects) { project in
            LabeledContent {
                Button("빼기") { model.remove(project.url) }
            } label: {
                Text(project.name)
                Text("\((project.url.path as NSString).abbreviatingWithTildeInPath) · \(state(project))")
            }
        }
    }

    private func state(_ project: DStackModel.Project) -> String {
        switch project.reading {
        case .open(let run): "열린 실행: \(run.title)"
        case .unsupported: "지원하지 않는 형식이에요"
        case .noOpenRun: DStackStore.hasStore(project.url) ? "열린 실행이 없어요" : "D-STACK 저장소가 없어요"
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
        model.add(url)
    }
}
