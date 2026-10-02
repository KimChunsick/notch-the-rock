import AppKit
import CryptoKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import DStack

/// A temporary directory removed when the test is done with it. Read-only copies are made writable
/// again first so they can be removed.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("P59-T144-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: "dstack-tests.\(url.lastPathComponent)")
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", url.path]).waitUntilExit()
        try? FileManager.default.removeItem(at: url)
    }
}

func iso(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

/// Writes a trimmed store shaped like a real one under `project/.dstack`: two milestones, six plans
/// (two done, two in progress, one pending, one ready), seven tasks (four committed), four R rows
/// (one withdrawn), the cases and two sealed review rounds. Every name is made up.
func writeStore(
    at project: URL,
    version: String = "2",
    current: String? = "20261001T090000Z_sample-app",
    status: String = "open",
    lastTaskAt: String = "2026-10-02T09:50:00Z",
    lastReviewAt: String = "2026-10-02T09:45:00Z",
    lastEvidenceAt: String = "2026-10-02T09:40:00Z"
) throws {
    let store = project.appendingPathComponent(".dstack")
    let id = current ?? "20261001T090000Z_sample-app"
    let run = store.appendingPathComponent("runs/\(id)")
    try FileManager.default.createDirectory(at: run.appendingPathComponent("review"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: store.appendingPathComponent("local"), withIntermediateDirectories: true)
    func put(_ text: String, _ path: String) throws {
        try text.write(to: store.appendingPathComponent(path), atomically: false, encoding: .utf8)
    }
    try put("\(version)\n", "version")
    if let current { try put("\(current)\n", "local/CURRENT") }
    try put("""
    id\t\(id)
    slug\tsample-app
    status\t\(status)
    started_at\t2026-10-01T09:00:00Z
    closed_at\t

    """, "runs/\(id)/meta.tsv")
    try put("""
    ---
    work_type: cli
    review: on
    ---
    # 샘플 목표

    ## 요구사항

    - [ ] **R01** 첫 번째 요구사항이에요. — accept: 테스트로 확인해요.
    - [ ] **R02** 두 번째 요구사항이에요. — accept: 테스트로 확인해요.
    - [ ] **R03** 뺀 요구사항이에요. — accept: 테스트로 확인해요. — withdrawn: 사용자가 뺐어요.
    - [ ] **R04** 네 번째 요구사항이에요. — accept: 리뷰로 확인해요.

    """, "runs/\(id)/request.md")
    try put("""
    {"v": 2, "milestones": [{"id": "M2", "slug": "extras", "order": 2}, {"id": "M1", "slug": "base", "order": 1}],
     "plans": [
      {"id": "P1", "milestone": "M1", "slug": "core", "status": "done", "tasks": [
        {"id": "T1", "slug": "a", "covers": ["R01"], "commit": "aaa1111", "done_at": "2026-10-01T10:00:00Z"},
        {"id": "T2", "slug": "b", "covers": ["R01"], "commit": "bbb2222", "done_at": "2026-10-01T11:00:00Z"}]},
      {"id": "P2", "milestone": "M1", "slug": "shell", "status": "done", "tasks": [
        {"id": "T3", "slug": "c", "covers": ["R02"], "commit": "ccc3333", "done_at": "2026-10-01T12:00:00Z"}]},
      {"id": "P3", "milestone": "M2", "slug": "widget", "status": "in-progress", "tasks": [
        {"id": "T4", "slug": "d", "covers": ["R04"], "commit": "ddd4444", "done_at": "\(lastTaskAt)"},
        {"id": "T5", "slug": "e", "covers": ["R04"], "commit": "", "done_at": ""}]},
      {"id": "P4", "milestone": "M2", "slug": "sync", "status": "in-progress", "tasks": [
        {"id": "T6", "slug": "f", "covers": ["R02"], "commit": "", "done_at": ""}]},
      {"id": "P5", "milestone": "M2", "slug": "docs", "status": "pending", "tasks": [
        {"id": "T7", "slug": "g", "covers": ["R02"], "commit": "", "done_at": ""}]},
      {"id": "P6", "milestone": "M2", "slug": "polish", "status": "ready", "tasks": []}
     ]}
    """, "runs/\(id)/plan.json")
    try put("""
    R\tcase\tkind\tstatus\tartifact\tsha256\tproduced_by\trecorded_at\tnote
    R01\tc1\ttest\tmet\tartifacts/P1/R01-green.txt\tabc\tgeneral-dev\t2026-10-01T10:00:00Z\tgreen
    R01\tc2\tcli\topen\t-\t-\t-\t-\t-
    R02\tc1\ttest\topen\t-\t-\t-\t-\t-
    R03\tc1\ttest\tmet\tartifacts/P1/R03-green.txt\tdef\tgeneral-dev\t2026-10-01T11:00:00Z\tgreen
    R04\tc1\treview\tmet\treview/codex-review-002.md\tghi\treview\t\(lastEvidenceAt)\tsealed

    """, "runs/\(id)/cases.tsv")
    try put("""
    001\tplan\tP1\tcodex-review-001.md\t2026-10-01T10:30:00Z\t0\t1\t0
    002\tplan\tP3\tcodex-review-002.md\t\(lastReviewAt)\t0\t2\t0

    """, "runs/\(id)/review/index.tsv")
}

/// Every file and directory under `root` with its mode, modification time and content hash.
func snapshot(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let url as URL in enumerator {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        var line = "\(attributes[.posixPermissions] ?? "") \(date)"
        if attributes[.type] as? FileAttributeType == .typeRegular {
            line += " " + SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        result[url.path] = line
    }
    return result
}

@MainActor
final class SilentHost: NotchHost {
    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// A plugin reading `claudeProjects` and `fileSystemRoot` under a temporary directory, never the
/// real ~/.claude, with settings in a defaults suite of its own.
@MainActor
func makePlugin(root: URL, now: Date, interval: Duration = .seconds(5)) throws -> (DStackPlugin, UserDefaults) {
    let id = DStackPlugin.manifest.id
    let suite = "dstack-tests.\(root.lastPathComponent)"
    let storage = try PluginStorage(
        directory: root.appendingPathComponent("storage"),
        defaultsSuiteName: suite,
        keychainService: suite
    )
    let context = NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: SilentHost(), storage: storage)
    let discovery = ProjectDiscovery(
        claudeProjects: root.appendingPathComponent("claude/projects"),
        fileSystemRoot: root.appendingPathComponent("fs")
    )
    try FileManager.default.createDirectory(at: discovery.claudeProjects, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: discovery.fileSystemRoot, withIntermediateDirectories: true)
    return (DStackPlugin(context: context, discovery: discovery, now: { now }, interval: interval), storage.defaults)
}

/// Creates `relative` under the plugin's file system root and lists it in its Claude Code projects
/// folder under its encoded name, as Claude Code does for a folder it was started in.
func addClaudeProject(_ relative: String, root: URL) throws -> URL {
    let folder = root.appendingPathComponent("fs/\(relative)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoded = ProjectDiscovery.encode("/" + relative)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/projects/\(encoded)"), withIntermediateDirectories: true)
    return folder
}

/// How far the outermost ink of `view` (any channel at least 14 over black) stays from its left,
/// right and bottom edges, drawn offscreen at the size it is given.
@MainActor
func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    window.setContentSize(hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    try #require(maxX >= 0, "no ink")
    let scale = window.backingScaleFactor
    return (CGFloat(minX) / scale, CGFloat(width - 1 - maxX) / scale, CGFloat(height - 1 - maxY) / scale)
}

/// The view's fitting size, and a render of it on black written to `$DSTACK_CAPTURE_DIR/<name>.png`
/// when that variable is set.
@MainActor
@discardableResult
func render(_ view: some View, named name: String) throws -> CGSize {
    let hosting = NSHostingView(rootView: view.background(.black).environment(\.colorScheme, .dark))
    hosting.appearance = NSAppearance(named: .darkAqua)
    let size = hosting.fittingSize
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    if let directory = ProcessInfo.processInfo.environment["DSTACK_CAPTURE_DIR"] {
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
    return size
}
