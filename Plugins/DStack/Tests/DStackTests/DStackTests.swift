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
    #expect(DStackStore(project: old).read() == .unsupported("1"))

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

/// Claude Code turns every character other than a letter or digit into '-', so a hyphenated
/// folder name decodes only by looking at what exists: the candidate with a store wins.
@MainActor
@Test func R50__discovery_decodes_hyphenated_folder_names() throws {
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

    plugin.model.refresh()
    #expect(plugin.model.projects.map(\.name).sorted() == [".side-proj", "my-app"])
    #expect(plugin.model.projects.allSatisfy { $0.isDiscovered })
    // Without an open run a project shows in settings only.
    #expect(plugin.model.screenProjects.map(\.name) == ["my-app"])
}

/// Folders added in settings join the discovered ones, removed ones leave, and both choices are
/// kept in the plugin's own defaults.
@MainActor
@Test func R50__settings_add_and_remove_folders() throws {
    let temp = try TempDir()
    let discovered = try addClaudeProject("work/found", root: temp.url)
    try writeStore(at: discovered)
    let manual = temp.url.appendingPathComponent("elsewhere/manual")
    try writeStore(at: manual)

    let (plugin, defaults) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"))
    let model = plugin.model
    model.refresh()
    #expect(model.projects.map(\.name) == ["found"])

    model.add(manual)
    #expect(model.projects.map(\.name).sorted() == ["found", "manual"])
    #expect(model.projects.first { $0.name == "manual" }?.isDiscovered == false)

    model.remove(discovered)
    #expect(model.projects.map(\.name) == ["manual"])
    let reopened = ProjectFolders(defaults: defaults)
    #expect(reopened.resolve(discovered: [discovered]).map(\.lastPathComponent) == ["manual"])

    model.add(discovered)
    model.remove(manual)
    #expect(model.projects.map(\.name) == ["found"])
}

/// Reading, discovering, refreshing and rendering change nothing in a read-only copy of the store.
@MainActor
@Test func R50__the_plugin_never_writes_to_a_store() throws {
    let temp = try TempDir()
    let project = try addClaudeProject("work/sample", root: temp.url)
    try writeStore(at: project)
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"))
    let fs = temp.url.appendingPathComponent("fs")
    let chmod = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "a-w", fs.path])
    chmod.waitUntilExit()
    let before = try snapshot(fs)
    #expect(before.count > 8)

    _ = DStackStore(project: project).read()
    _ = DStackStore(project: project).signature()
    plugin.activate()
    plugin.model.refresh()
    #expect(plugin.model.screenProjects.count == 1)
    _ = try render(try #require(plugin.expandedTab).content, named: "R50-render-readonly-screen-T144")
    _ = try render(try #require(plugin.tile).content(.wide), named: "R50-render-readonly-wide-T144")
    plugin.deactivate()

    #expect(try snapshot(fs) == before)
}

/// The screen draws to its edges, fills a wider offer and fits the notch with one or two projects;
/// with none it says how to add a folder.
@MainActor
@Test func R50__screen_renders_one_two_and_no_projects() throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let tab = try #require(plugin.expandedTab)
    #expect(tab.title == "D-STACK")

    plugin.model.refresh()
    let empty = try render(tab.content, named: "R50-render-empty-T144")
    #expect(empty.width > 0 && empty.width <= 390 && empty.height > 0 && empty.height <= 400, "\(empty)")

    let first = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: first)
    plugin.model.add(first)
    let one = try render(tab.content, named: "R50-render-one-T144")
    #expect(one.width > 0 && one.width <= 390 && one.height > empty.height && one.height <= 400, "\(one)")
    let insets = try inkInsets(tab.content)
    for (side, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
        #expect(inset <= 2, "\(inset) pt of empty space at the \(side) edge")
    }
    let wider = try inkInsets(tab.content.frame(width: one.width + 80))
    #expect(wider.left <= 2 && wider.right <= 2, "does not fill a wider offer: \(wider)")

    let second = temp.url.appendingPathComponent("fs/other-app")
    try writeStore(at: second, lastTaskAt: "2026-10-02T09:52:00Z")
    plugin.model.add(second)
    #expect(plugin.model.screenProjects.map(\.name) == ["other-app", "sample-app"])
    let two = try render(tab.content, named: "R50-render-screen-T144")
    #expect(two.width <= 390 && two.height > one.height, "\(two)")
    #expect(NSHostingView(rootView: tab.content.frame(width: 360, height: 400)).fittingSize.height <= 400)
}

/// The tile comes wide (goal, overall bar, plans in progress) or small (ring with percent and the
/// project name) and fits the home's 190×90 and 90×90 frames, with or without a project.
@MainActor
@Test func R50__tiles_are_wide_or_small_and_fit() throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let tile = try #require(plugin.tile)
    #expect(tile.supportedSizes == [.wide, .small])

    plugin.model.refresh()
    for (size, limit) in [(TileSize.wide, CGSize(width: 190, height: 90)), (.small, CGSize(width: 90, height: 90))] {
        let fitted = try render(tile.content(size), named: "R50-render-\(size)-empty-T144")
        #expect(fitted.width > 0 && fitted.width <= limit.width && fitted.height <= limit.height, "\(size) \(fitted)")
    }

    let project = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: project)
    plugin.model.add(project)
    for (size, limit) in [(TileSize.wide, CGSize(width: 190, height: 90)), (.small, CGSize(width: 90, height: 90))] {
        let fitted = try render(tile.content(size), named: "R50-render-\(size)-T144")
        #expect(fitted.width > 0 && fitted.width <= limit.width && fitted.height > 0 && fitted.height <= limit.height, "\(size) \(fitted)")
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
    plugin.model.add(project)
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
