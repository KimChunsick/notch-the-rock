import CryptoKit
import Foundation

/// One milestone's plans: how many are done out of all of them.
struct MilestoneProgress: Equatable, Sendable {
    let id: String
    let slug: String
    let done: Int
    let total: Int

    /// Whether every plan of the milestone is done; one without plans is not finished.
    var isFinished: Bool { total > 0 && done == total }
}

/// A plan by id and slug, e.g. `P3 widget`.
struct PlanRef: Equatable, Sendable {
    let id: String
    let slug: String
}

/// The newest thing that happened in a run and when, e.g. `P3 리뷰 2 봉인`.
struct Activity: Equatable, Sendable {
    let date: Date
    let text: String
}

/// A request row's status as `dstack report` prints it.
enum RequirementStatus: Equatable, Sendable {
    case met, unmet, abstain, blocked
    /// Superseded by the rows it was split into.
    case skipped
    case deferred, withdrawn
}

struct Requirement: Equatable, Sendable {
    let id: String
    let status: RequirementStatus
}

/// What an open run's files say about its progress.
struct RunProgress: Equatable, Sendable {
    var runID: String
    var status: String
    var startedAt: Date?
    var title: String
    var milestones: [MilestoneProgress]
    var plansDone: Int
    var plansTotal: Int
    var inProgress: [PlanRef]
    var tasksCommitted: Int
    var tasksTotal: Int
    /// Every request row in request order, with its report status.
    var requirements: [Requirement]
    var latest: Activity?

    /// Rows `dstack report` counts as MET.
    var requirementsMet: Int { requirements.filter { $0.status == .met }.count }

    /// MET's denominator as `dstack report` counts it: every row but withdrawn and deferred ones.
    var requirementsCounted: Int { requirements.filter { $0.status != .withdrawn && $0.status != .deferred }.count }

    /// Done plans over all plans, as `dstack status` counts them; 0 without plans.
    var fraction: Double { plansTotal == 0 ? 0 : Double(plansDone) / Double(plansTotal) }

    /// Whether every plan is done; a run without plans yet is not finished. The screen and the
    /// tiles leave a finished run out like a closed one.
    var isFinished: Bool { plansTotal > 0 && plansDone == plansTotal }

    /// The milestones with plans left, in order: the screen and the tiles leave finished ones out.
    var remainingMilestones: [MilestoneProgress] { milestones.filter { !$0.isFinished } }
}

/// What a project's store holds, as far as this plugin can tell.
enum StoreReading: Equatable, Sendable {
    case open(RunProgress)
    /// No pointer, an empty pointer (the run was closed) or a run that is not open.
    case noOpenRun
    /// A store whose files this reader does not understand, with a short reason such as
    /// "plan.json 구조가 달라요".
    case unsupported(String)
}

/// The sha256 of evidence artifacts, kept by path, size and modification time so a reader that
/// keeps it hashes a file again only after it changed.
struct ArtifactDigests: Sendable {
    private var entries: [String: (size: Int, date: Date, digest: String)] = [:]
    /// How many files were hashed.
    private(set) var hashed = 0

    /// The file's sha256 in lowercase hex, nil when it is missing or unreadable.
    mutating func digest(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let date = attributes[.modificationDate] as? Date else { return nil }
        if let entry = entries[url.path], entry.size == size, entry.date == date { return entry.digest }
        // Read, not mapped: a mapped file truncated while being hashed would crash the host.
        guard let data = try? Data(contentsOf: url) else { return nil }
        hashed += 1
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        entries[url.path] = (size, date, digest)
        return digest
    }
}

/// What `read()` looks at, as modification times and sizes, so a caller rereads only after it
/// changed.
struct StoreSignature: Equatable, Sendable {
    /// The store's own files.
    let store: String
    /// The artifacts of met cases: overwriting one changes no store file.
    let artifacts: String

    /// The part a reading depends on: only an open reading looked at the artifacts, so access to
    /// cases.tsv coming back does not count as a change for a store that could not be read.
    func of(_ reading: StoreReading) -> StoreSignature {
        if case .open = reading { self } else { StoreSignature(store: store, artifacts: "") }
    }
}

/// Reads one project's D-STACK store (`<project>/.dstack`). It only opens files for reading and
/// never runs the `dstack` CLI, some of whose verbs write.
struct DStackStore: Sendable {
    static let supportedVersion = "2"
    let project: URL

    private var store: URL { project.appendingPathComponent(".dstack") }

    /// Whether the project has a run pointer, empty or not: `.dstack/local/CURRENT`, where dstack
    /// keeps it, or `.dstack/CURRENT`.
    static func hasStore(_ project: URL) -> Bool {
        DStackStore(project: project).pointer != nil
    }

    private var pointer: URL? {
        ["local/CURRENT", "CURRENT"]
            .map { store.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The open run's id, nil when the pointer is missing or empty.
    private var runID: String? {
        guard let pointer, let id = Self.text(pointer)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return id
    }

    /// The modification times and sizes of the files `read()` looks at, so a caller rereads only
    /// after one of them changed.
    func signature() -> StoreSignature {
        var files = [store.appendingPathComponent("version")]
        if let pointer { files.append(pointer) }
        var artifacts: [URL] = []
        if let runID {
            let run = store.appendingPathComponent("runs").appendingPathComponent(runID)
            files += ["meta.tsv", "request.md", "plan.json", "cases.tsv", "review/index.tsv"].map { run.appendingPathComponent($0) }
            artifacts = (Self.cases(run) ?? []).filter { $0[3] == "met" }.map { project.appendingPathComponent($0[4]) }
        }
        func stats(_ files: [URL]) -> String {
            files.map { file in
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let date = attributes?[.modificationDate] as? Date
                return "\(file.path)=\(date?.timeIntervalSinceReferenceDate ?? -1),\(attributes?[.size] as? Int ?? -1)"
            }.joined(separator: "\n")
        }
        return StoreSignature(store: stats(files), artifacts: stats(artifacts))
    }

    /// The open run's progress, `.noOpenRun` for a store without one (no or an empty pointer, a run
    /// that is not open) and `.unsupported` for files it cannot read or not in the shape dstack
    /// writes. A file a run does not have yet (plan.json, cases.tsv, review/index.tsv) counts as
    /// empty.
    func read() -> StoreReading {
        var digests = ArtifactDigests()
        return read(digests: &digests)
    }

    /// `read()` with artifact digests kept from earlier reads.
    func read(digests: inout ArtifactDigests) -> StoreReading {
        let version = Self.text(store.appendingPathComponent("version"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A folder without a store has no open run; settings tell it apart.
        if version == nil, pointer == nil { return .noOpenRun }
        guard let version else { return .unsupported("version 파일이 없어요") }
        guard version == Self.supportedVersion else { return .unsupported("지원하지 않는 버전이에요 (\(version))") }
        guard let pointer else { return .noOpenRun }
        guard Self.text(pointer) != nil else { return .unsupported("CURRENT 값이 이상해요") }
        guard let runID else { return .noOpenRun }
        guard !runID.contains("/"), runID != ".", runID != ".." else { return .unsupported("CURRENT 값이 이상해요") }
        let run = store.appendingPathComponent("runs").appendingPathComponent(runID)
        guard let metaText = Self.text(run.appendingPathComponent("meta.tsv")) else { return .unsupported("meta.tsv가 없어요") }
        let meta = Self.table(metaText).reduce(into: [String: String]()) { $0[$1[0]] = $1.count > 1 ? $1[1] : "" }
        guard let status = meta["status"], !status.isEmpty else { return .unsupported("meta.tsv에 상태가 없어요") }
        guard status == "open" else { return .noOpenRun }

        // Every run has a request; one that is missing or unreadable is not a run without
        // requirements.
        guard let request = Self.text(run.appendingPathComponent("request.md")) else { return .unsupported("request.md가 없어요") }
        let plan: PlanFile
        let planURL = run.appendingPathComponent("plan.json")
        if FileManager.default.fileExists(atPath: planURL.path) {
            guard let data = try? Data(contentsOf: planURL),
                  let decoded = try? JSONDecoder().decode(PlanFile.self, from: data) else { return .unsupported("plan.json 구조가 달라요") }
            plan = decoded
        } else {
            plan = PlanFile(milestones: [], plans: [])
        }
        guard let cases = Self.cases(run) else { return .unsupported("cases.tsv 줄 형식이 달라요") }
        // review/index.tsv: round, kind, target, file, sealed_at and counts, without a header.
        guard let rounds = Self.rows(run.appendingPathComponent("review/index.tsv"), header: nil, columns: 5, key: /\d+/) else {
            return .unsupported("review/index.tsv 줄 형식이 달라요")
        }
        // A sealed round's file never changes, so index.tsv's modification time covers it. A round
        // listed but not readable is not a round without verdicts.
        var verdicts: [String: String] = [:]
        for round in rounds {
            guard !round[3].contains("/") else { return .unsupported("review/index.tsv 줄 형식이 달라요") }
            guard let text = Self.text(run.appendingPathComponent("review").appendingPathComponent(round[3])) else {
                return .unsupported("리뷰 파일을 읽지 못했어요 (\(round[3]))")
            }
            for line in text.split(separator: "\n") {
                if let match = line.wholeMatch(of: /\| (R\d+) \| (\w+) \|.*/) { verdicts[String(match.1)] = String(match.2) }
            }
        }
        let plans = plan.plans
        let tasks = plans.flatMap { plan in (plan.tasks ?? []).map { (plan, $0) } }
        let requirements = Self.requirements(
            request: request,
            covered: Set(tasks.flatMap { $0.1.covers ?? [] }),
            cases: cases,
            verdicts: verdicts,
            // An artifact path is relative to the project root.
            isIntact: { row in digests.digest(project.appendingPathComponent(row[4])) == row[5] }
        )

        // Ties keep the earlier source: a commit says more than the evidence recorded with it.
        var candidates: [Activity] = []
        candidates += tasks.compactMap { plan, task in
            guard !(task.commit ?? "").isEmpty, let date = Self.date(task.done_at) else { return nil }
            return Activity(date: date, text: "\(plan.id) 작업 \(task.id) 커밋")
        }
        candidates += rounds.compactMap { row in
            guard let date = Self.date(row[4]) else { return nil }
            return Activity(date: date, text: "\(row[2]) 리뷰 \(Int(row[0]).map(String.init) ?? row[0]) 봉인")
        }
        candidates += cases.compactMap { row in
            guard let date = Self.date(row[7]) else { return nil }
            return Activity(date: date, text: "\(row[0]) 증거 추가")
        }
        let latest = candidates.reduce(nil as Activity?) { newest, next in
            guard let newest else { return next }
            return next.date > newest.date ? next : newest
        }

        let milestones = plan.milestones.enumerated()
            .sorted { ($0.element.order ?? $0.offset, $0.offset) < ($1.element.order ?? $1.offset, $1.offset) }
            .map { _, milestone in
                let own = plans.filter { $0.milestone == milestone.id }
                return MilestoneProgress(id: milestone.id, slug: milestone.slug ?? "", done: own.filter { $0.status == "done" }.count, total: own.count)
            }
        return .open(RunProgress(
            runID: runID,
            status: meta["status"] ?? "",
            startedAt: Self.date(meta["started_at"]),
            title: Self.title(request) ?? meta["slug"] ?? runID,
            milestones: milestones,
            plansDone: plans.filter { $0.status == "done" }.count,
            plansTotal: plans.count,
            inProgress: plans.filter { $0.status == "in-progress" }.map { PlanRef(id: $0.id, slug: $0.slug ?? "") },
            tasksCommitted: tasks.filter { !($0.1.commit ?? "").isEmpty }.count,
            tasksTotal: tasks.count,
            requirements: requirements,
            latest: latest
        ))
    }

    /// "방금", "3분 전", "3시간 전" or "3일 전".
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "방금"
        case ..<3600: return "\(seconds / 60)분 전"
        case ..<86_400: return "\(seconds / 3600)시간 전"
        default: return "\(seconds / 86_400)일 전"
        }
    }

    // MARK: - Files

    private struct PlanFile: Decodable {
        struct Milestone: Decodable {
            let id: String
            let slug: String?
            let order: Int?
        }
        struct Plan: Decodable {
            let id: String
            let milestone: String?
            let slug: String?
            let status: String?
            let tasks: [Task]?
        }
        struct Task: Decodable {
            let id: String
            let covers: [String]?
            let commit: String?
            let done_at: String?
        }
        // Both are required: a plan.json without them is not one dstack wrote.
        let milestones: [Milestone]
        let plans: [Plan]
    }

    private static func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// cases.tsv: R, case, kind, status, artifact, sha256, produced_by, recorded_at, note.
    private static func cases(_ run: URL) -> [[String]]? {
        rows(run.appendingPathComponent("cases.tsv"), header: ["R", "case"], columns: 8, key: /R\d+/)
    }

    private static func table(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The rows of a tab-separated file, none when it is missing. Nil when it is unreadable or a
    /// row has fewer than `columns` fields or a first field other than `key`; a first row starting
    /// with `header` is skipped.
    private static func rows(_ url: URL, header: [String]?, columns: Int, key: Regex<Substring>) -> [[String]]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let text = text(url) else { return nil }
        var rows = table(text)
        if let header, rows.first.map({ Array($0.prefix(header.count)) }) == header { rows.removeFirst() }
        return rows.allSatisfy { $0.count >= columns && $0[0].wholeMatch(of: key) != nil } ? rows : nil
    }

    private static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, text != "-" else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// The first `# ` heading after the front matter, else a `title:` field in it.
    private static func title(_ request: String) -> String? {
        var lines = request.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        var field: String?
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            field = lines[lines.index(after: lines.startIndex)..<end]
                .first { $0.hasPrefix("title:") }
                .map { $0.dropFirst("title:".count).trimmingCharacters(in: .whitespaces) }
            lines = lines[lines.index(after: end)...]
        }
        let heading = lines.first { $0.hasPrefix("# ") }.map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        return [heading, field].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Each request row's status as `dstack report` combines it, rows read in order with
    /// `verdicts` holding the verdict of the latest sealed round that judged each row:
    /// - a withdrawn, deferred or superseded row keeps its marker's status;
    /// - `check coverage`: a task covers the row and the ledger has a row past open;
    /// - the ledger: an unreported case fails the row; open cases do not count against a row that
    ///   otherwise passes, and retired ones are not counted at all;
    /// - verify's per-field evidence: a met row of a kind the request's `e2e` field asks for (`none`
    ///   asks for `review`, any other value for `cli`, `capture` or `transcript`, no field for none)
    ///   and, with `unit_tests: on`, a met `test` row;
    /// - verify's sha256 recheck: a met case whose artifact is gone or no longer has the recorded
    ///   bytes (`isIntact` false) fails the row even when its other cases would pass it;
    /// - the review: a `partial` or `absent` verdict fails the row.
    /// A row that passes but has a blocked or abstain case is blocked or abstain. The project policy
    /// ceiling, branch containment and `check decisions` are not reproduced: they need the CLI or
    /// files outside the run, so a row only they would fail reads as met here.
    private static func requirements(request: String, covered: Set<String>, cases: [[String]], verdicts: [String: String], isIntact: ([String]) -> Bool) -> [Requirement] {
        let front = fields(request)
        let e2eKinds: Set<String>? = switch front["e2e"] {
        case nil: nil
        case "none": ["review"]
        default: ["cli", "capture", "transcript"]
        }
        let ledger = Dictionary(grouping: cases.filter { $0[3] != "retired" }) { $0[0] }
        return requestRows(request).map { row in
            if let marker = row.marker { return Requirement(id: row.id, status: marker) }
            let own = ledger[row.id] ?? []
            let statuses = Set(own.map { $0[3] })
            let metKinds = Set(own.filter { $0[3] == "met" }.map { $0[2] })
            let failed = !covered.contains(row.id)
                || statuses.subtracting(["open"]).isEmpty
                || statuses.contains("unreported")
                || e2eKinds.map { metKinds.isDisjoint(with: $0) } ?? false
                || (front["unit_tests"] == "on" && !metKinds.contains("test"))
                || own.contains { $0[3] == "met" && !isIntact($0) }
                || ["partial", "absent"].contains(verdicts[row.id])
            let status: RequirementStatus = failed ? .unmet
                : statuses.contains("blocked") ? .blocked
                : statuses.contains("abstain") ? .abstain
                : .met
            return Requirement(id: row.id, status: status)
        }
    }

    /// The `key: value` fields of the request's front matter.
    private static func fields(_ request: String) -> [String: String] {
        let lines = request.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        return lines[1..<end].reduce(into: [:]) { fields, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// The request's R rows in order, each with the status of the marker dstack writes after its
    /// `accept:` when it was withdrawn, deferred or superseded.
    private static func requestRows(_ request: String) -> [(id: String, marker: RequirementStatus?)] {
        let markers: [(String, RequirementStatus)] = [("withdrawn:", .withdrawn), ("deferred:", .deferred), ("superseded-by:", .skipped)]
        return request.split(separator: "\n").compactMap { line in
            guard let match = line.wholeMatch(of: /- \[.\] \*\*(R\d+)\*\*.*/) else { return nil }
            let segments = line.components(separatedBy: " — ")
            let after = segments.firstIndex { $0.hasPrefix("accept:") }.map { segments[($0 + 1)...] } ?? []
            let marker = after.lazy.compactMap { segment in markers.first { segment.hasPrefix($0.0) }?.1 }.first
            return (String(match.1), marker)
        }
    }
}
