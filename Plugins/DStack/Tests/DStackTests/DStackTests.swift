import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import DStack

/// The goal title, the milestone, plan, task and requirement counts, the plans in progress and the
/// latest activity all come from the store's files.
@Test func R53__reader_counts_the_open_run() throws {
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
@Test func R53__latest_activity_is_the_newest_of_task_review_and_evidence() throws {
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
@Test func R53__unsupported_version_and_no_open_run_are_told_apart() throws {
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
@Test func R53__malformed_stores_read_as_unsupported_with_a_reason() throws {
    let temp = try TempDir()
    let run = "runs/20261001T090000Z_sample-app"
    let broken: [(path: String, text: String?, reason: String)] = [
        ("local/CURRENT", "20261001T000000Z_gone\n", "meta.tsv가 없어요"),
        ("\(run)/meta.tsv", nil, "meta.tsv가 없어요"),
        ("\(run)/request.md", nil, "request.md가 없어요"),
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
@Test func R53__discovery_decodes_hyphenated_folder_names() async throws {
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
@Test func R53__discovery_retries_misses_and_drops_vanished_folders() async throws {
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
@Test func R53__settings_add_and_remove_folders() async throws {
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

    // A folder picked through a symlink is kept by its resolved path.
    let link = temp.url.appendingPathComponent("manual-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: manual)
    await model.add(link)
    #expect(defaults.stringArray(forKey: ProjectFolders.addedKey) == [discovered.path, manual.path])
    #expect(model.projects.map(\.name).sorted() == ["found", "manual"])
}

/// No file in D-STACK stores or project folders is written: reading, discovering, refreshing,
/// adding and removing folders in settings and rendering create, change or remove nothing under the
/// test's root (the read-only fixture projects with their .dstack trees, Claude Code's project
/// folders and the plugin's storage directory), byte for byte, mode for mode and mtime for mtime.
/// The settings changes land in the plugin's own defaults suite and nowhere else.
@MainActor
@Test func R54__no_file_in_dstack_stores_or_project_folders_is_written() async throws {
    let temp = try TempDir()
    let project = try addClaudeProject("work/sample", root: temp.url)
    try writeStore(at: project)
    let manual = temp.url.appendingPathComponent("fs/elsewhere/manual")
    try writeStore(at: manual, status: "closed")
    let (plugin, defaults) = try makePlugin(root: temp.url, now: iso("2026-10-02T10:00:00Z"))
    let suite = "dstack-tests.\(temp.url.lastPathComponent)"
    let trees = ["fs", "claude"].map { temp.url.appendingPathComponent($0).path }
    let chmod = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "a-w"] + trees)
    chmod.waitUntilExit()
    let before = try snapshot(temp.url)
    #expect(before.count > 20 && before.keys.contains { $0.hasSuffix("/\(temp.url.lastPathComponent)/storage") }, "\(before.keys.sorted())")
    #expect((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)

    _ = DStackStore(project: project).read()
    _ = DStackStore(project: project).signature()
    plugin.activate()
    await plugin.model.refresh(retry: true)
    #expect(plugin.model.screenProjects.count == 1)
    await plugin.model.add(manual)
    await plugin.model.remove(project)
    #expect(plugin.model.projects.map(\.name) == ["manual"])
    await plugin.model.add(project)
    await plugin.model.remove(manual)
    #expect(plugin.model.projects.map(\.name) == ["sample"])
    _ = try render(try #require(plugin.expandedTab).content, named: "R54-render-readonly-screen-T151")
    _ = try render(try #require(plugin.tile).content(.wide), named: "R54-render-readonly-wide-T151")
    _ = try render(try #require(plugin.tile).content(.small), named: "R54-render-readonly-small-T151")
    _ = try render(DStackSettingsView(model: plugin.model), named: "R54-render-readonly-settings-T151")
    plugin.deactivate()

    #expect(try snapshot(temp.url) == before)
    // The plugin's defaults suite holds the settings and only them; the process's own defaults
    // hold neither list.
    let domain = defaults.persistentDomain(forName: suite) ?? [:]
    #expect(Set(domain.keys) == [ProjectFolders.addedKey, ProjectFolders.removedKey], "\(domain)")
    #expect(domain[ProjectFolders.addedKey] as? [String] == [project.path])
    #expect(domain[ProjectFolders.removedKey] as? [String] == [manual.path])
    #expect(UserDefaults.standard.object(forKey: ProjectFolders.addedKey) == nil)
    #expect(UserDefaults.standard.object(forKey: ProjectFolders.removedKey) == nil)
}

/// The plugin's code launches no process and calls nothing that creates, changes, moves or removes a
/// file: no Process, NSTask or posix_spawn, no FileManager call that writes, no write(to:) on Data or
/// String and no file handle for writing, anywhere in its sources, comments included.
@Test func R54__plugin_code_launches_no_process_and_writes_no_file() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
    #expect(files.count >= 5, "\(sources.path)")
    let forbidden: [(String, Regex<Substring>)] = [
        ("a process launch", /\bProcess\b|\bNSTask\b|posix_spawn/),
        ("a FileManager write", /\b(?:createDirectory|createFile|removeItem|trashItem|moveItem|copyItem|replaceItem|linkItem|createSymbolicLink|setAttributes)\b/),
        ("write(to:)", /\.write\s*\(\s*(?:to|toFile|toURL)\s*:/),
        ("a file handle for writing", /FileHandle\s*\(\s*for(?:Writing|Updating)/),
    ]
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (name, pattern) in forbidden {
            // Simple word boundaries: the default Unicode ones join `Process.run` into one word.
            for match in text.matches(of: pattern.wordBoundaryKind(.simple)) {
                Issue.record("\(file.lastPathComponent): \(name) — \(match.output)")
            }
        }
    }
}

/// The screen draws to its edges, fills a wider offer and fits the notch with one or two projects;
/// with none it says how to add a folder.
@MainActor
@Test func R53__screen_renders_one_two_and_no_projects() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let tab = try #require(plugin.expandedTab)
    #expect(tab.title == "D-STACK")

    await plugin.model.refresh()
    let empty = try render(tab.content, named: "R53-render-empty-T151")
    #expect(empty.width > 0 && empty.width <= 390 && empty.height > 0 && empty.height <= 400, "\(empty)")

    let first = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: first)
    await plugin.model.add(first)
    let one = try render(tab.content, named: "R53-render-one-T151")
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
    let two = try render(tab.content, named: "R53-render-screen-T151")
    #expect(two.width <= 390 && two.height > one.height, "\(two)")
    #expect(NSHostingView(rootView: tab.content.frame(width: 360, height: 400)).fittingSize.height <= 400)
}

/// The screen shows every value. The wide tile shows the goal title, the plans bar with done/total,
/// a strip with a segment per milestone with plans left (labeled with its id and done/total, filled
/// by its share; M1, whose plans are all done, is left out on both),
/// task and requirement counts, the plans in progress and the latest activity; the small one a ring
/// with the percentage, the project name, the plan in progress and the task count. Without any
/// project the tile says so and draws no progress. Every state fits the home's 190×90 and 90×90
/// frames.
@MainActor
@Test func R53__screen_and_widget_renders_show_their_values() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let tile = try #require(plugin.tile)
    #expect(tile.supportedSizes == [.wide, .small])
    let limits: [TileSize: CGSize] = [.wide: CGSize(width: 190, height: 90), .small: CGSize(width: 90, height: 90)]
    func fits(_ size: TileSize, _ shown: CGSize) -> Bool {
        shown.width > 0 && shown.width <= limits[size]!.width && shown.height > 0 && shown.height <= limits[size]!.height
    }

    await plugin.model.refresh()
    let emptyWide = try look(tile.content(.wide), named: "R53-render-wide-empty-T151")
    #expect(emptyWide.text.contains("보여줄D-STACK실행이없어요") && emptyWide.text.contains("설정에서폴더를더할수있어요"), "\(emptyWide.text)")
    #expect(emptyWide.greenBands == 0 && fits(.wide, emptyWide.size), "\(emptyWide)")
    let emptySmall = try look(tile.content(.small), named: "R53-render-small-empty-T151")
    #expect(emptySmall.text.contains("D-STACK"), "\(emptySmall.text)")
    #expect(emptySmall.greenBands == 0 && fits(.small, emptySmall.size), "\(emptySmall)")

    let project = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: project)
    try splitMilestones(in: project)
    await plugin.model.add(project)
    let wide = try look(tile.content(.wide), named: "R53-render-wide-T151")
    for token in ["샘플목표", "계획3/6", "작업4/7", "요구사항2/3", "P3", "P4", "3분전", "P3작업T4커밋", "M21/3", "M30/1"] {
        #expect(wide.text.contains(token), "\(token) missing from the wide tile: \(wide.text)")
    }
    // The plans bar and, below it, the milestone strip: one bar per milestone with plans left, each
    // filled by its share of done plans.
    #expect(wide.greenBands == 2 && fits(.wide, wide.size), "\(wide)")
    let strip = wide.shares.count == 2 ? wide.shares[1] : []
    #expect(strip.count == 2, "\(wide.shares)")
    for (share, expected) in zip(strip, [1.0 / 3, 0]) {
        #expect(abs(share - expected) < 0.04, "\(strip)")
    }
    let small = try look(tile.content(.small), named: "R53-render-small-T151")
    for token in ["50%", "sample-app", "P3", "4/7"] {
        #expect(small.text.contains(token), "\(token) missing from the small tile: \(small.text)")
    }
    #expect(small.greenBands == 1 && fits(.small, small.size), "\(small)")
    let screen = try look(try #require(plugin.expandedTab).content, named: "R53-render-screen-values-T151")
    for token in ["sample-app", "샘플목표", "계획3/6", "50%", "작업4/7커밋", "요구사항2/3충족", "M2extras", "M3later", "P3widget", "P4sync", "3분전", "P3작업T4커밋"] {
        #expect(screen.text.contains(token), "\(token) missing from the screen: \(screen.text)")
    }
}

/// A store it could not read is never trusted across a retry. When access comes back without any
/// modification time changing, the once-a-minute retry and the next activation read it again; a
/// poll before then still reports it unreadable.
@MainActor
@Test func R53__a_store_that_becomes_readable_again_is_read_on_the_next_retry() async throws {
    let temp = try TempDir()
    let clock = Clock(iso("2026-10-02T10:00:00Z"))
    let (plugin, _) = try makePlugin(root: temp.url, now: clock.date)
    let model = plugin.model
    let project = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: project)
    let run = project.appendingPathComponent(".dstack/runs/20261001T090000Z_sample-app")
    func access(_ file: String, _ mode: Int, touch: Date? = nil) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: mode]
        if let touch { attributes[.modificationDate] = touch }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: run.appendingPathComponent(file).path)
    }
    func isOpen() -> Bool {
        if case .open = model.projects.first?.reading { true } else { false }
    }

    try access("meta.tsv", 0o000)
    await model.add(project)
    #expect(model.projects.map(\.reading) == [.unsupported("meta.tsv가 없어요")])
    let signature = DStackStore(project: project).signature()
    try access("meta.tsv", 0o644)
    #expect(DStackStore(project: project).signature() == signature)
    clock.date += 30
    await model.refresh()
    #expect(!isOpen(), "an unreadable store was read again within a minute")
    clock.date += 31
    await model.refresh()
    #expect(isOpen(), "not read again a minute later: \(model.projects.map(\.reading))")

    // A file that goes unreadable with a new modification time is read at once.
    try access("cases.tsv", 0o000, touch: iso("2026-10-02T10:05:00Z"))
    await model.refresh()
    #expect(model.projects.map(\.reading) == [.unsupported("cases.tsv 줄 형식이 달라요")])
    try access("cases.tsv", 0o644)
    await model.refresh()
    #expect(!isOpen(), "an unreadable store was read again within a minute")
    plugin.activate()
    for _ in 0..<100 where !isOpen() {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(isOpen(), "not read again on activation: \(model.projects.map(\.reading))")
    plugin.deactivate()

    // An unreadable request.md is not an open run titled by its slug with no requirements, and
    // once it is readable again the next activation reads the real title and counts.
    try access("request.md", 0o000, touch: iso("2026-10-02T10:10:00Z"))
    await model.refresh()
    #expect(model.projects.map(\.reading) == [.unsupported("request.md가 없어요")])
    try access("request.md", 0o644)
    await model.refresh()
    #expect(!isOpen(), "an unreadable store was read again within a minute")
    plugin.activate()
    for _ in 0..<100 where !isOpen() {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard case .open(let progress) = model.projects.first?.reading else {
        Issue.record("request.md not read again on activation: \(model.projects.map(\.reading))")
        plugin.deactivate()
        return
    }
    #expect(progress.title == "샘플 목표")
    #expect(progress.requirementsMet == 2 && progress.requirementsLive == 3)
    plugin.deactivate()
}

/// With nothing but a store it cannot read, the tiles and the screen say the format could not be
/// read and why, instead of claiming there is no open run.
@MainActor
@Test func R53__tiles_and_screen_show_a_store_they_cannot_read() async throws {
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
        let shown = try look(tile.content(size), named: size == .wide ? "R53-render-unsupported-T151" : "R53-render-unsupported-small-T151")
        for token in ["형식을읽지못했어요", "plan.json", "odd-app"] {
            #expect(shown.text.contains(token), "\(token) missing from the \(size) tile: \(shown.text)")
        }
        #expect(!shown.text.contains("실행이없어요"), "\(size): \(shown.text)")
        #expect(shown.greenBands == 0 && shown.size.width <= limit.width && shown.size.height <= limit.height, "\(size) \(shown)")
    }
    let screen = try look(try #require(plugin.expandedTab).content, named: "R53-render-unsupported-screen-T151")
    for token in ["odd-app", "형식을읽지못했어요", "plan.json구조가달라요"] {
        #expect(screen.text.contains(token), "\(token) missing from the screen: \(screen.text)")
    }
}

/// While the screen or tile is shown the plugin rereads changed files on its interval, and stops
/// once nothing shows it.
@MainActor
@Test func R53__polls_while_shown_and_stops_when_hidden() async throws {
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

/// A milestone whose plans are all done leaves the screen card and the wide tile's strip; the other
/// milestones keep their order and share the strip. The reader still counts every milestone. A card
/// whose milestones are all done has no milestone section at all, so it is as tall as one without
/// milestones.
@MainActor
@Test func R58__finished_milestone_bars_leave_the_screen_and_the_tile() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let project = temp.url.appendingPathComponent("fs/sample-app")
    try writeStore(at: project)
    try splitMilestones(in: project)
    await plugin.model.add(project)
    let shown = try #require(plugin.model.screenProjects.first)
    guard case .open(let run) = shown.reading else {
        Issue.record("\(shown.reading)")
        return
    }
    #expect(run.milestones.map(\.id) == ["M1", "M2", "M3"] && run.plansDone == 3 && run.plansTotal == 6, "\(run)")

    let screen = try look(try #require(plugin.expandedTab).content, named: "R58-render-T176")
    #expect(!screen.text.contains("M1base"), "the finished milestone is on the screen: \(screen.text)")
    for token in ["sample-app", "계획3/6", "M2extras", "M3later"] {
        #expect(screen.text.contains(token), "\(token) missing from the screen: \(screen.text)")
    }

    let wide = try look(try #require(plugin.tile).content(.wide), named: "R58-render-wide-T176")
    #expect(!wide.text.contains("M12/2"), "the finished milestone is on the tile: \(wide.text)")
    for token in ["계획3/6", "M21/3", "M30/1"] {
        #expect(wide.text.contains(token), "\(token) missing from the wide tile: \(wide.text)")
    }
    #expect(wide.greenBands == 2, "\(wide)")
    let strip = wide.shares.count == 2 ? wide.shares[1] : []
    #expect(strip.count == 2, "\(wide.shares)")
    for (share, expected) in zip(strip, [1.0 / 3, 0]) {
        #expect(abs(share - expected) < 0.04, "\(strip)")
    }

    var done = run
    done.milestones = run.milestones.map { MilestoneProgress(id: $0.id, slug: $0.slug, done: $0.total, total: $0.total) }
    var none = run
    none.milestones = []
    func card(_ run: RunProgress) -> ProjectCard {
        ProjectCard(project: DStackModel.Project(url: project, reading: .open(run), isDiscovered: false, hasStore: true), now: iso("2026-10-02T09:53:20Z"))
    }
    let doneHeight = try render(card(done).frame(width: 360), named: "R58-render-card-all-done-T176").height
    let noneHeight = try render(card(none).frame(width: 360), named: "R58-render-card-no-milestones-T176").height
    #expect(abs(doneHeight - noneHeight) < 0.5, "all done \(doneHeight) pt, none \(noneHeight) pt")
}

/// An open run whose plans are all done leaves the screen and the tile, which show the run still in
/// progress even though the finished one was active more recently. Settings still list both, and a
/// run without any plan yet is not finished.
@MainActor
@Test func R58__finished_open_runs_leave_the_screen_and_the_tile() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let finished = temp.url.appendingPathComponent("fs/finished-app")
    try writeStore(at: finished, lastTaskAt: "2026-10-02T09:52:00Z")
    try finishPlans(in: finished)
    let active = temp.url.appendingPathComponent("fs/active-app")
    try writeStore(at: active)
    await plugin.model.add(finished)
    await plugin.model.add(active)
    #expect(Set(plugin.model.projects.map(\.name)) == ["finished-app", "active-app"])
    #expect(plugin.model.screenProjects.map(\.name) == ["active-app"])
    #expect(plugin.model.tileProject?.name == "active-app")

    let screen = try look(try #require(plugin.expandedTab).content, named: "R58-render-screen-T176")
    #expect(screen.text.contains("active-app") && !screen.text.contains("finished-app"), "\(screen.text)")
    let tile = try #require(plugin.tile)
    let small = try look(tile.content(.small), named: "R58-render-small-T176")
    #expect(small.text.contains("active-app") && !small.text.contains("finished-app"), "\(small.text)")
    let wide = try look(tile.content(.wide), named: "R58-render-wide-active-T176")
    #expect(wide.text.contains("계획2/6") && !wide.text.contains("계획6/6"), "\(wide.text)")

    let fresh = temp.url.appendingPathComponent("fs/new-app")
    try writeStore(at: fresh)
    try replace("runs/20261001T090000Z_sample-app/plan.json", in: fresh, with: #"{"milestones": [], "plans": []}"#)
    await plugin.model.add(fresh)
    #expect(plugin.model.screenProjects.map(\.name) == ["active-app", "new-app"])
}

/// With every run closed or finished, the screen and the tile say there is no run to show, without
/// drawing any progress.
@MainActor
@Test func R58__with_every_run_closed_or_finished_the_screen_shows_none() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let finished = temp.url.appendingPathComponent("fs/finished-app")
    try writeStore(at: finished)
    try finishPlans(in: finished)
    let closed = temp.url.appendingPathComponent("fs/closed-app")
    try writeStore(at: closed, status: "closed")
    await plugin.model.add(finished)
    await plugin.model.add(closed)
    #expect(plugin.model.projects.count == 2)
    #expect(plugin.model.screenProjects.isEmpty && plugin.model.tileProject == nil)

    let screen = try look(try #require(plugin.expandedTab).content, named: "R58-render-empty-T176")
    #expect(screen.text.contains("보여줄D-STACK실행이없어요") && screen.greenBands == 0, "\(screen)")
    let wide = try look(try #require(plugin.tile).content(.wide), named: "R58-render-wide-empty-T176")
    #expect(wide.text.contains("보여줄D-STACK실행이없어요") && wide.greenBands == 0, "\(wide)")
}

/// With only finished open runs, the wide tile says there is no run to show and that finished runs
/// are left out, not that there is no open run or that a folder could be added, and fits the tile.
@MainActor
@Test func R58__a_tile_with_only_finished_runs_says_they_are_left_out() async throws {
    let temp = try TempDir()
    let (plugin, _) = try makePlugin(root: temp.url, now: iso("2026-10-02T09:53:20Z"))
    let finished = temp.url.appendingPathComponent("fs/finished-app")
    try writeStore(at: finished)
    try finishPlans(in: finished)
    await plugin.model.add(finished)
    #expect(plugin.model.projects.count == 1 && plugin.model.tileProject == nil)

    let wide = try look(try #require(plugin.tile).content(.wide), named: "R58-render-T178")
    #expect(wide.text.contains("보여줄D-STACK실행이없어요") && wide.text.contains("계획을모두끝낸실행은빼요"), "\(wide.text)")
    #expect(!wide.text.contains("열린") && !wide.text.contains("폴더"), "\(wide.text)")
    #expect(wide.greenBands == 0 && wide.size.width <= 190 && wide.size.height <= 90, "\(wide)")
}
