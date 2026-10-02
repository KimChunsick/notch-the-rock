import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import DStack

/// The goal title, the milestone, plan, task and requirement counts, the plans in progress and the
/// latest activity all come from the store's files.
@Test func R50__reader_counts_the_open_run() throws {
    let temp = try TempDir()
    let project = temp.url.appendingPathComponent("sample-app")
    try writeStore(at: project)

    guard case .open(let run) = DStackStore(project: project).read() else {
        Issue.record("no open run in \(DStackStore(project: project).read())")
        return
    }
    #expect(run.runID == "20261001T090000Z_sample-app")
    #expect(run.status == "open")
    #expect(run.startedAt == iso("2026-10-01T09:00:00Z"))
    #expect(run.title == "샘플 목표")
    #expect(run.milestones == [
        MilestoneProgress(id: "M1", slug: "base", done: 2, total: 2),
        MilestoneProgress(id: "M2", slug: "extras", done: 0, total: 4),
    ])
    #expect(run.plansDone == 2 && run.plansTotal == 6)
    #expect(abs(run.fraction - 2.0 / 6.0) < 0.0001)
    #expect(run.inProgress == [PlanRef(id: "P3", slug: "widget"), PlanRef(id: "P4", slug: "sync")])
    #expect(run.tasksCommitted == 4 && run.tasksTotal == 7)
    // R03 is withdrawn: neither live nor met although it has a met case.
    #expect(run.requirementsMet == 2 && run.requirementsLive == 3)
    #expect(run.latest == Activity(date: iso("2026-10-02T09:50:00Z"), text: "P3 작업 T4 커밋"))
    #expect(DStackStore.relative(iso("2026-10-02T09:50:00Z"), now: iso("2026-10-02T09:53:20Z")) == "3분 전")
    #expect(DStackStore.relative(iso("2026-10-02T09:50:00Z"), now: iso("2026-10-02T09:50:30Z")) == "방금")
    #expect(DStackStore.relative(iso("2026-10-02T06:50:00Z"), now: iso("2026-10-02T09:50:30Z")) == "3시간 전")
    #expect(DStackStore.relative(iso("2026-09-29T09:50:00Z"), now: iso("2026-10-02T09:50:30Z")) == "3일 전")
}

/// The latest activity is whichever is newest: a committed task, a sealed review round or added
/// evidence.
@Test func R50__latest_activity_is_the_newest_of_task_review_and_evidence() throws {
    let cases: [(task: String, review: String, evidence: String, expected: Activity)] = [
        ("2026-10-02T09:50:00Z", "2026-10-02T09:55:00Z", "2026-10-02T09:40:00Z",
         Activity(date: iso("2026-10-02T09:55:00Z"), text: "P3 리뷰 2 봉인")),
        ("2026-10-02T09:50:00Z", "2026-10-02T09:45:00Z", "2026-10-02T09:58:00Z",
         Activity(date: iso("2026-10-02T09:58:00Z"), text: "R04 증거 추가")),
    ]
    for item in cases {
        let temp = try TempDir()
        try writeStore(at: temp.url, lastTaskAt: item.task, lastReviewAt: item.review, lastEvidenceAt: item.evidence)
        guard case .open(let run) = DStackStore(project: temp.url).read() else {
            Issue.record("no open run")
            continue
        }
        #expect(run.latest == item.expected)
    }
}

/// Another store version reads as unsupported; a missing or empty pointer or a closed run reads as
/// no open run.
@Test func R50__unsupported_version_and_no_open_run_are_told_apart() throws {
    let temp = try TempDir()
    let old = temp.url.appendingPathComponent("old")
    try writeStore(at: old, version: "1")
    #expect(DStackStore(project: old).read() == .unsupported("지원하지 않는 버전이에요 (1)"))

    let empty = temp.url.appendingPathComponent("empty")
    try writeStore(at: empty, current: "")
    #expect(DStackStore(project: empty).read() == .noOpenRun)

    let missing = temp.url.appendingPathComponent("missing")
    try writeStore(at: missing, current: nil)
    #expect(DStackStore(project: missing).read() == .noOpenRun)
    #expect(!DStackStore.hasStore(missing))
    #expect(DStackStore.hasStore(empty))

    let closed = temp.url.appendingPathComponent("closed")
    try writeStore(at: closed, status: "closed")
    #expect(DStackStore(project: closed).read() == .noOpenRun)
}

/// Files not in the shape dstack writes read as unsupported with a short reason, never as no open
/// run or as an empty open run. An empty plan and a run without cases or review rounds yet stay
/// valid open runs.
@Test func R50__malformed_stores_read_as_unsupported_with_a_reason() throws {
    let temp = try TempDir()
    let run = "runs/20261001T090000Z_sample-app"
    let broken: [(path: String, text: String?, reason: String)] = [
        ("local/CURRENT", "20261001T000000Z_gone\n", "meta.tsv가 없어요"),
        ("\(run)/meta.tsv", nil, "meta.tsv가 없어요"),
        ("\(run)/meta.tsv", "id\tx\nslug\tsample-app\n", "meta.tsv에 상태가 없어요"),
        ("\(run)/meta.tsv", "status\t\n", "meta.tsv에 상태가 없어요"),
        ("\(run)/plan.json", "{}", "plan.json 구조가 달라요"),
        ("\(run)/plan.json", "{\"milestones\": []}", "plan.json 구조가 달라요"),
        ("\(run)/plan.json", "{\"plans\": [", "plan.json 구조가 달라요"),
        ("\(run)/cases.tsv", "R\tcase\tkind\tstatus\nR01\tc1\ttest\tmet\n", "cases.tsv 줄 형식이 달라요"),
        ("\(run)/cases.tsv", "<html>\n", "cases.tsv 줄 형식이 달라요"),
        ("\(run)/review/index.tsv", "001\tplan\tP1\n", "review/index.tsv 줄 형식이 달라요"),
        ("\(run)/review/index.tsv", "round\tkind\ttarget\tfile\tsealed_at\n", "review/index.tsv 줄 형식이 달라요"),
        ("local/CURRENT", "../elsewhere\n", "CURRENT 값이 이상해요"),
    ]
    for (index, item) in broken.enumerated() {
        let project = temp.url.appendingPathComponent("broken-\(index)")
        try writeStore(at: project)
        try replace(item.path, in: project, with: item.text)
        #expect(DStackStore(project: project).read() == .unsupported(item.reason), "\(item.path): \(item.text ?? "removed")")
    }

    let emptyPlan = temp.url.appendingPathComponent("empty-plan")
    try writeStore(at: emptyPlan)
    try replace("\(run)/plan.json", in: emptyPlan, with: "{\"v\": 2, \"milestones\": [], \"plans\": []}")
    guard case .open(let empty) = DStackStore(project: emptyPlan).read() else {
        Issue.record("an empty plan is not an open run")
        return
    }
    #expect(empty.plansTotal == 0 && empty.milestones.isEmpty && empty.tasksTotal == 0)

    let early = temp.url.appendingPathComponent("early")
    try writeStore(at: early)
    try replace("\(run)/cases.tsv", in: early, with: nil)
    try replace("\(run)/review/index.tsv", in: early, with: nil)
    guard case .open(let started) = DStackStore(project: early).read() else {
        Issue.record("a run without cases or rounds is not an open run")
        return
    }
    #expect(started.requirementsMet == 0 && started.latest?.text == "P3 작업 T4 커밋")
}

/// Claude Code turns every character other than a letter or digit into '-', so a hyphenated
/// folder name decodes only by looking at what exists: the candidate with a store wins.
@MainActor
@Test func R50__discovery_decodes_hyphenated_folder_names() async throws {
    let temp = try TempDir()
    #expect(ProjectDiscovery.encode("/work/my-app.v2/.cfg") == "-work-my-app-v2--cfg")
    let hyphenated = try addClaudeProject("work/my-app", root: temp.url)
    try writeStore(at: hyphenated)
    // Same encoding, no store.
    _ = try addClaudeProject("work/my/app", root: temp.url)
    let hidden = try addClaudeProject("work/.side-proj", root: temp.url)
    try writeStore(at: hidden, current: "")
    _ = try addClaudeProject("work/plain", root: temp.url)
    try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("claude/projects/-work-gone"), withIntermediateDirectories: true)

    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"))
    let discovery = ProjectDiscovery(claudeProjects: temp.url.appendingPathComponent("claude/projects"), fileSystemRoot: temp.url.appendingPathComponent("fs"))
    #expect(Set(discovery.candidates(for: "-work-my-app").map(\.lastPathComponent)) == ["my-app", "app"])
    #expect(discovery.candidates(for: "-work-gone").isEmpty)

    await plugin.model.refresh()
    #expect(plugin.model.projects.map(\.name).sorted() == [".side-proj", "my-app"])
    #expect(plugin.model.projects.allSatisfy { $0.isDiscovered && $0.hasStore })
    // Without an open run a project shows in settings only.
    #expect(plugin.model.screenProjects.map(\.name) == ["my-app"])
}

/// Discovery keeps only the Claude Code projects that decoded to a folder with a store. The others
/// are tried again on each activation and at most once a minute while shown, and a found folder
/// that vanished is dropped, so a restored folder is found again without restarting the app.
@MainActor
@Test func R50__discovery_retries_misses_and_drops_vanished_folders() async throws {
    let temp = try TempDir()
    let clock = Clock(iso("2026-10-02T10:00:00Z"))
    let (plugin, _) = try makePlugin(root: temp.url, now: clock.date)
    let model = plugin.model
    // Claude Code lists the folder, but it is not on disk yet.
    let folder = try addClaudeProject("work/later", root: temp.url)
    try FileManager.default.removeItem(at: folder)
    await model.refresh()
    #expect(model.projects.isEmpty)

    try writeStore(at: folder)
    clock.date += 30
    await model.refresh()
    #expect(model.projects.isEmpty, "a miss was retried within a minute")
    clock.date += 31
    await model.refresh()
    #expect(model.projects.map(\.name) == ["later"])

    try FileManager.default.removeItem(at: folder)
    await model.refresh()
    #expect(model.projects.isEmpty)
    try writeStore(at: folder)
    await model.refresh()
    #expect(model.projects.isEmpty, "a miss was retried within a minute")

    plugin.activate()
    for _ in 0..<100 where model.projects.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.projects.map(\.name) == ["later"])
    plugin.deactivate()
}

/// Folders added in settings join the discovered ones, removed ones leave, and both choices are
/// kept in the plugin's own defaults.
@MainActor
@Test func R50__settings_add_and_remove_folders() async throws {
    let temp = try TempDir()
    let discovered = try addClaudeProject("work/found", root: temp.url)
    try writeStore(at: discovered)
    let manual = temp.url.appendingPathComponent("elsewhere/manual")
    try writeStore(at: manual)

    let (plugin, defaults) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"))
    let model = plugin.model
    await model.refresh()
    #expect(model.projects.map(\.name) == ["found"])

    await model.add(manual)
    #expect(model.projects.map(\.name).sorted() == ["found", "manual"])
    #expect(model.projects.first { $0.name == "manual" }?.isDiscovered == false)

    await model.remove(discovered)
    #expect(model.projects.map(\.name) == ["manual"])
    let reopened = ProjectFolders(defaults: defaults)
    #expect(reopened.resolve(discovered: [discovered]).map(\.lastPathComponent) == ["manual"])

    await model.add(discovered)
    await model.remove(manual)
    #expect(model.projects.map(\.name) == ["found"])
}

/// No file in D-STACK stores or project folders is written: reading, discovering, refreshing,
/// adding and removing folders in settings and rendering leave every fixture project, its .dstack
/// tree and Claude Code's project folders byte for byte and mtime for mtime unchanged, even though
/// they are read-only. The plugin's own settings live in the app's plugin storage (`storage/` and
/// the defaults suite here), outside those trees.
@MainActor
@Test func R50__no_file_in_dstack_stores_or_project_folders_is_written() async throws {
    let temp = try TempDir()
    let project = try addClaudeProject("work/sample", root: temp.url)
    try writeStore(at: project)
    let manual = temp.url.appendingPathComponent("fs/elsewhere/manual")
    try writeStore(at: manual, status: "closed")
    let (plugin, defaults) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"))
    let trees = ["fs", "claude"].map { temp.url.appendingPathComponent($0) }
    let chmod = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "a-w"] + trees.map(\.path))
    chmod.waitUntilExit()
    let before = try trees.map(snapshot)
    #expect(before[0].count > 16 && before[1].count >= 2)

    _ = DStackStore(project: project).read()
    _ = DStackStore(project: project).signature()
    plugin.activate()
    await plugin.model.refresh(retryDiscovery: true)
    #expect(plugin.model.screenProjects.count == 1)
    await plugin.model.add(manual)
    await plugin.model.remove(project)
    #expect(plugin.model.projects.map(\.name) == ["manual"])
    await plugin.model.add(project)
    await plugin.model.remove(manual)
    #expect(plugin.model.projects.map(\.name) == ["sample"])
    _ = try render(try #require(plugin.expandedTab).content, named: "R50-render-readonly-screen-T150")
    _ = try render(try #require(plugin.tile).content(.wide), named: "R50-render-readonly-wide-T150")
    _ = try render(try #require(plugin.tile).content(.small), named: "R50-render-readonly-small-T150")
    _ = try render(DStackSettingsView(model: plugin.model), named: "R50-render-readonly-settings-T150")
    plugin.deactivate()

    #expect(try trees.map(snapshot) == before)
    // The settings changes went to the plugin's storage.
    #expect(defaults.stringArray(forKey: ProjectFolders.removedKey) == [manual.path])
}

/// The screen draws to its edges, fills a wider offer and fits the notch with one or two projects;
/// with none it says how to add a folder.
@MainActor
@Test func R50__screen_renders_one_two_and_no_projects() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let tab = try #require(plugin.expandedTab)
    #expect(tab.title == "D-STACK")

    await plugin.model.refresh()
    let empty = try render(tab.content, named: "R50-render-empty-T150")
    #expect(empty.width > 0 && empty.width <= 390 && empty.height > 0 && empty.height <= 400, "\(empty)")

    let first = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: first)
    await plugin.model.add(first)
    let one = try render(tab.content, named: "R50-render-one-T150")
    #expect(one.width > 0 && one.width <= 390 && one.height > empty.height && one.height <= 400, "\(one)")
    let insets = try inkInsets(tab.content)
    for (side, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
        #expect(inset <= 2, "\(inset) pt of empty space at the \(side) edge")
    }
    let wider = try inkInsets(tab.content.frame(width: one.width + 80))
    #expect(wider.left <= 2 && wider.right <= 2, "does not fill a wider offer: \(wider)")

    let second = temp.url.appendingPathComponent("fs/other-app")
    try writeStore(at: second, lastTaskAt: "2026-10-02T09:52:00Z")
    await plugin.model.add(second)
    #expect(plugin.model.screenProjects.map(\.name) == ["other-app", "sample-app"])
    let two = try render(tab.content, named: "R50-render-screen-T150")
    #expect(two.width <= 390 && two.height > one.height, "\(two)")
    #expect(NSHostingView(rootView: tab.content.frame(width: 360, height: 400)).fittingSize.height <= 400)
}

/// The wide tile shows the goal title, the plans bar with done/total, a milestone strip, task and
/// requirement counts, the plans in progress and the latest activity; the small one a ring with
/// the percentage, the project name, the plan in progress and the task count. Without any project
/// the tile says so and draws no progress. Every state fits the home's 190×90 and 90×90 frames.
@MainActor
@Test func R50__widget_renders_show_their_content() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let tile = try #require(plugin.tile)
    #expect(tile.supportedSizes == [.wide, .small])
    let limits: [TileSize: CGSize] = [.wide: CGSize(width: 190, height: 90), .small: CGSize(width: 90, height: 90)]
    func fits(_ size: TileSize, _ shown: CGSize) -> Bool {
        shown.width > 0 && shown.width <= limits[size]!.width && shown.height > 0 && shown.height <= limits[size]!.height
    }

    await plugin.model.refresh()
    let emptyWide = try look(tile.content(.wide), named: "R50-render-wide-empty-T150")
    #expect(emptyWide.text.contains("열린D-STACK실행이없어요"), "\(emptyWide.text)")
    #expect(emptyWide.greenBands == 0 && fits(.wide, emptyWide.size), "\(emptyWide)")
    let emptySmall = try look(tile.content(.small), named: "R50-render-small-empty-T150")
    #expect(emptySmall.text.contains("D-STACK"), "\(emptySmall.text)")
    #expect(emptySmall.greenBands == 0 && fits(.small, emptySmall.size), "\(emptySmall)")

    let project = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: project)
    await plugin.model.add(project)
    let wide = try look(tile.content(.wide), named: "R50-render-wide-T150")
    for token in ["샘플목표", "계획2/6", "작업4/7", "요구사항2/3", "P3", "P4", "3분전", "P3작업T4커밋"] {
        #expect(wide.text.contains(token), "\(token) missing from the wide tile: \(wide.text)")
    }
    // The plans bar and, below it, the milestone strip.
    #expect(wide.greenBands == 2 && fits(.wide, wide.size), "\(wide)")
    let small = try look(tile.content(.small), named: "R50-render-small-T150")
    for token in ["33%", "sample-app", "P3", "4/7"] {
        #expect(small.text.contains(token), "\(token) missing from the small tile: \(small.text)")
    }
    #expect(small.greenBands == 1 && fits(.small, small.size), "\(small)")
}

/// With nothing but a store it cannot read, the tiles and the screen say the format could not be
/// read and why, instead of claiming there is no open run.
@MainActor
@Test func R50__tiles_and_screen_show_a_store_they_cannot_read() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let project = temp.url.appendingPathComponent("fs/odd-app")
    try writeStore(at: project)
    try replace("runs/20261001T090000Z_sample-app/plan.json", in: project, with: "{}")
    let closed = temp.url.appendingPathComponent("fs/done-app")
    try writeStore(at: closed, status: "closed")
    await plugin.model.add(project)
    await plugin.model.add(closed)
    #expect(plugin.model.tileProject?.name == "odd-app")

    let tile = try #require(plugin.tile)
    for (size, limit) in [(TileSize.wide, CGSize(width: 190, height: 90)), (.small, CGSize(width: 90, height: 90))] {
        let shown = try look(tile.content(size), named: size == .wide ? "R50-render-unsupported-T150" : "R50-render-unsupported-small-T150")
        for token in ["형식을읽지못했어요", "plan.json", "odd-app"] {
            #expect(shown.text.contains(token), "\(token) missing from the \(size) tile: \(shown.text)")
        }
        #expect(!shown.text.contains("실행이없어요"), "\(size): \(shown.text)")
        #expect(shown.greenBands == 0 && shown.size.width <= limit.width && shown.size.height <= limit.height, "\(size) \(shown)")
    }
    let screen = try look(try #require(plugin.expandedTab).content, named: "R50-render-unsupported-screen-T150")
    for token in ["odd-app", "형식을읽지못했어요", "plan.json구조가달라요"] {
        #expect(screen.text.contains(token), "\(token) missing from the screen: \(screen.text)")
    }
}

/// While the screen or tile is shown the plugin rereads changed files on its interval, and stops
/// once nothing shows it.
@MainActor
@Test func R50__polls_while_shown_and_stops_when_hidden() async throws {
    let temp = try TempDir()
    let project = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: project)
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"), interval: .milliseconds(50))
    await plugin.model.add(project)
    plugin.activate()
    #expect(plugin.model.screenProjects.count == 1)

    plugin.model.appeared()
    try writeStore(at: project, status: "closed")
    for _ in 0..<100 where !plugin.model.screenProjects.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(plugin.model.screenProjects.isEmpty)

    plugin.model.disappeared()
    try await Task.sleep(for: .milliseconds(120))
    try writeStore(at: project, status: "open")
    try await Task.sleep(for: .milliseconds(300))
    #expect(plugin.model.screenProjects.isEmpty)
    plugin.deactivate()
}
