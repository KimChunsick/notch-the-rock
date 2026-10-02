import Foundation

/// One milestone's plans: how many are done out of all of them.
struct MilestoneProgress: Equatable, Sendable {
    let id: String
    let slug: String
    let done: Int
    let total: Int
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
    var requirementsMet: Int
    var requirementsLive: Int
    var latest: Activity?

    /// Done plans over all plans, as `dstack status` counts them; 0 without plans.
    var fraction: Double { plansTotal == 0 ? 0 : Double(plansDone) / Double(plansTotal) }
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

    /// The modification times of the files `read()` looks at, so a caller rereads only after one
    /// of them changed.
    func signature() -> String {
        var files = [store.appendingPathComponent("version")]
        if let pointer { files.append(pointer) }
        if let runID {
            let run = store.appendingPathComponent("runs").appendingPathComponent(runID)
            files += ["meta.tsv", "request.md", "plan.json", "cases.tsv", "review/index.tsv"].map { run.appendingPathComponent($0) }
        }
        return files.map { file in
            let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            return "\(file.path)=\(date?.timeIntervalSinceReferenceDate ?? -1)"
        }.joined(separator: "\n")
    }

    /// The open run's progress, `.noOpenRun` for a store without one (no or an empty pointer, a run
    /// that is not open) and `.unsupported` for files not in the shape dstack writes. A file a run
    /// does not have yet (plan.json, cases.tsv, review/index.tsv) counts as empty.
    func read() -> StoreReading {
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

        let request = Self.text(run.appendingPathComponent("request.md")) ?? ""
        let plan: PlanFile
        let planURL = run.appendingPathComponent("plan.json")
        if FileManager.default.fileExists(atPath: planURL.path) {
            guard let data = try? Data(contentsOf: planURL),
                  let decoded = try? JSONDecoder().decode(PlanFile.self, from: data) else { return .unsupported("plan.json 구조가 달라요") }
            plan = decoded
        } else {
            plan = PlanFile(milestones: [], plans: [])
        }
        // cases.tsv: R, case, kind, status, artifact, sha256, produced_by, recorded_at, note.
        guard let cases = Self.rows(run.appendingPathComponent("cases.tsv"), header: ["R", "case"], columns: 8, key: /R\d+/) else {
            return .unsupported("cases.tsv 줄 형식이 달라요")
        }
        // review/index.tsv: round, kind, target, file, sealed_at and counts, without a header.
        guard let rounds = Self.rows(run.appendingPathComponent("review/index.tsv"), header: nil, columns: 5, key: /\d+/) else {
            return .unsupported("review/index.tsv 줄 형식이 달라요")
        }
        let plans = plan.plans
        let tasks = plans.flatMap { plan in (plan.tasks ?? []).map { (plan, $0) } }
        let live = Self.liveRequirements(request)
        let met = Set(cases.filter { $0[3] == "met" }.map { $0[0] })

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
            requirementsMet: live.filter(met.contains).count,
            requirementsLive: live.count,
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

    /// R ids of the request's rows that still take work: not withdrawn, deferred or superseded,
    /// the markers dstack writes after a row's `accept:`.
    private static func liveRequirements(_ request: String) -> [String] {
        request.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.wholeMatch(of: /- \[.\] \*\*(R\d+)\*\*.*/) else { return nil }
            let segments = line.components(separatedBy: " — ")
            guard let accept = segments.firstIndex(where: { $0.hasPrefix("accept:") }) else { return String(match.1) }
            let skipped = segments[(accept + 1)...].contains { segment in
                ["withdrawn:", "deferred:", "superseded-by:"].contains { segment.hasPrefix($0) }
            }
            return skipped ? nil : String(match.1)
        }
    }
}
