import AppKit
import CryptoKit
import Foundation
import NotchKit
import SwiftUI
import Testing
import Vision
@testable import DStack

/// A temporary directory removed when the test is done with it. Read-only copies are made writable
/// again first so they can be removed.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("P59-T151-\(UUID().uuidString)")
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

/// A clock a test moves by hand. `read()` also counts the reads: the plugin reads its time once
/// per refresh.
final class Clock: @unchecked Sendable {
    var date: Date
    private(set) var reads = 0
    init(_ date: Date) { self.date = date }

    func read() -> Date {
        reads += 1
        return date
    }
}

/// Replaces the file at `path` under `project/.dstack` with `text`, or removes it when `text` is nil.
func replace(_ path: String, in project: URL, with text: String?) throws {
    let file = project.appendingPathComponent(".dstack/\(path)")
    try? FileManager.default.removeItem(at: file)
    if let text { try text.write(to: file, atomically: false, encoding: .utf8) }
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
    001\tplan\tP1\tcodex-review-001.md\t2026-10-01T10:30:00Z\t0\t1\t0
    002\tplan\tP3\tcodex-review-002.md\t\(lastReviewAt)\t0\t2\t0

    """, "runs/\(id)/review/index.tsv")
    try put("| R | verdict (covered\\|partial\\|absent) | evidence |\n|---|---|---|\n| R01 | covered | tests pass |\n", "runs/\(id)/review/codex-review-001.md")
    let review = "| R | verdict | evidence in the diff |\n|---|---|---|\n| R04 | covered | widget hunk |\n"
    try put(review, "runs/\(id)/review/codex-review-002.md")
    // Artifact paths are relative to the project root and carry the sha256 of what was recorded.
    let r01 = try artifact(".dstack/runs/\(id)/artifacts/P1/R01-green.txt", "R01 green\n", in: project)
    let r03 = try artifact(".dstack/runs/\(id)/artifacts/P1/R03-green.txt", "R03 green\n", in: project)
    try put("""
    R\tcase\tkind\tstatus\tartifact\tsha256\tproduced_by\trecorded_at\tnote
    R01\tc1\ttest\tmet\t.dstack/runs/\(id)/artifacts/P1/R01-green.txt\t\(r01)\tgeneral-dev\t2026-10-01T10:00:00Z\tgreen
    R01\tc2\tcli\topen\t-\t-\t-\t-\t-
    R02\tc1\ttest\topen\t-\t-\t-\t-\t-
    R03\tc1\ttest\tmet\t.dstack/runs/\(id)/artifacts/P1/R03-green.txt\t\(r03)\tgeneral-dev\t2026-10-01T11:00:00Z\tgreen
    R04\tc1\treview\tmet\t.dstack/runs/\(id)/review/codex-review-002.md\t\(sha256(review))\treview\t\(lastEvidenceAt)\tsealed

    """, "runs/\(id)/cases.tsv")
}

func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Writes an evidence artifact at `path` under the project root and returns its sha256 as the
/// ledger records it.
@discardableResult
func artifact(_ path: String, _ text: String, in project: URL) throws -> String {
    let file = project.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: false, encoding: .utf8)
    return sha256(text)
}

/// Makes the sample store's two milestones three, with 2/2, 1/3 and 0/1 plans done: P5 is done and
/// P6 moves to a new M3, so three plans of six are done.
func splitMilestones(in project: URL) throws {
    let path = "runs/20261001T090000Z_sample-app/plan.json"
    var plan = try String(contentsOf: project.appendingPathComponent(".dstack/\(path)"), encoding: .utf8)
    for (old, new) in [
        (#"{"id": "M1", "slug": "base", "order": 1}]"#, #"{"id": "M1", "slug": "base", "order": 1}, {"id": "M3", "slug": "later", "order": 3}]"#),
        (#""slug": "docs", "status": "pending""#, #""slug": "docs", "status": "done""#),
        (#"{"id": "P6", "milestone": "M2""#, #"{"id": "P6", "milestone": "M3""#),
    ] {
        try #require(plan.contains(old), "\(old)")
        plan = plan.replacingOccurrences(of: old, with: new)
    }
    try replace(path, in: project, with: plan)
}

/// Marks every plan of the sample store done, so all six of its plans are.
func finishPlans(in project: URL) throws {
    let path = "runs/20261001T090000Z_sample-app/plan.json"
    let plan = try String(contentsOf: project.appendingPathComponent(".dstack/\(path)"), encoding: .utf8)
    let finished = plan.replacing(/"status": "(?:in-progress|pending|ready)"/, with: #""status": "done""#)
    try #require(finished != plan)
    try replace(path, in: project, with: finished)
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
/// real ~/.claude, with settings in a defaults suite of its own. `now` is read on every use, so a
/// `Clock`'s date moves the plugin's time.
@MainActor
func makePlugin(root: URL, now: @escaping @autoclosure () -> Date, interval: Duration = .seconds(5)) throws -> (DStackPlugin, UserDefaults) {
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
    return (DStackPlugin(context: context, discovery: discovery, now: now, interval: interval), storage.defaults)
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

/// What a render of `view` on black at 4x shows: the text Vision reads in it, top to bottom without
/// spaces or middle dots, how many separate bands of rows hold green (the plans bar, the milestone
/// strip, the ring), for each band the green share of every separate bar crossing its middle row
/// (left to right; a bar is a run of non-black pixels) and its size in points. Writes the render to
/// `$DSTACK_CAPTURE_DIR/<name>.png` when that variable is set.
@MainActor
func look(_ view: some View, named name: String) throws -> (text: String, greenBands: Int, shares: [[Double]], size: CGSize) {
    let renderer = ImageRenderer(content: view.background(.black).environment(\.colorScheme, .dark))
    renderer.scale = 4
    let image = try #require(renderer.cgImage)
    if let directory = ProcessInfo.processInfo.environment["DSTACK_CAPTURE_DIR"] {
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ko-KR", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let text = (request.results ?? [])
        .sorted { (-$0.boundingBox.midY, $0.boundingBox.minX) < (-$1.boundingBox.midY, $1.boundingBox.minX) }
        .compactMap { $0.topCandidates(1).first?.string }
        .joined()
        .filter { !$0.isWhitespace && !"·•∙・".contains($0) }

    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    func isGreen(_ x: Int, _ y: Int) -> Bool {
        let i = (y * width + x) * 4
        let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        return g >= 120 && g > r + 60 && g > b + 40
    }
    var bands: [ClosedRange<Int>] = []
    for y in 0..<height where (0..<width).contains(where: { isGreen($0, y) }) {
        if let last = bands.last, last.upperBound == y - 1 {
            bands[bands.count - 1] = last.lowerBound...y
        } else {
            bands.append(y...y)
        }
    }
    let shares = bands.map { band -> [Double] in
        let y = (band.lowerBound + band.upperBound) / 2
        var result: [Double] = [], inked = 0, green = 0
        for x in 0...width {
            let i = (y * width + min(x, width - 1)) * 4
            if x < width, max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                inked += 1
                if isGreen(x, y) { green += 1 }
            } else if inked > 0 {
                result.append(Double(green) / Double(inked))
                (inked, green) = (0, 0)
            }
        }
        return result
    }
    return (text, bands.count, shares, CGSize(width: CGFloat(width) / 4, height: CGFloat(height) / 4))
}
