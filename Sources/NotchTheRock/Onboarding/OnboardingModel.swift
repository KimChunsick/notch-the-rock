import Foundation
import Observation

/// Whether the first-launch onboarding is done, kept in the app's own defaults domain.
///
/// Launch arguments for automation (the milestone captures):
///   --skip-onboarding    this launch shows no onboarding and does not mark it completed
///   --reset-onboarding   clears the completed mark first, so this launch shows it again
/// Both together clear the mark and show nothing: the next plain launch is a first launch.
struct OnboardingRecord {
    static let completedKey = "OnboardingCompleted"

    let defaults: UserDefaults

    var isCompleted: Bool { defaults.bool(forKey: Self.completedKey) }

    func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
    }

    /// Applies the launch arguments above and says whether this launch shows the onboarding.
    func showsAtLaunch(arguments: [String]) -> Bool {
        if arguments.contains("--reset-onboarding") {
            defaults.removeObject(forKey: Self.completedKey)
        }
        if arguments.contains("--skip-onboarding") { return false }
        return !isCompleted
    }
}

/// The onboarding steps and the permissions they turn on. The window only draws `step` and calls
/// these methods. While the window is up (`start()` to `finish()`) the model follows both permissions
/// on the 권한 step every `pollInterval`, so a grant made in System Settings shows without a relaunch.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: CaseIterable {
        case welcome
        case permissions
        case usage
        case done
    }

    /// What a permission card shows.
    enum PermissionState: Equatable {
        case off
        case on
        /// Registered as a login item; the user still has to allow it in System Settings.
        case needsApproval
        /// Turning it on failed; the text says why, in the system's words.
        case failed(String)

        static func accessibility(trusted: Bool) -> PermissionState {
            trusted ? .on : .off
        }

        /// `.notFound` is what the system reports before the app has ever registered, so it is off.
        static func loginItem(_ status: SystemPermissions.LoginItemStatus, failure: String?) -> PermissionState {
            switch status {
            case .enabled: .on
            case .requiresApproval: .needsApproval
            case .notRegistered, .notFound: failure.map { .failed($0) } ?? .off
            }
        }

        var label: String {
            switch self {
            case .off: "꺼짐"
            case .on: "켜짐"
            case .needsApproval: "허용 필요"
            case .failed(let reason): reason
            }
        }
    }

    /// Where the model reads and changes the permissions. `.system` is `SystemPermissions`, the one
    /// place the app touches Accessibility trust and the login item.
    struct Permissions {
        var isAccessibilityTrusted: @MainActor () -> Bool
        var requestAccessibility: @MainActor () -> Void
        var openAccessibilitySettings: @MainActor () -> Void
        var loginItemStatus: @MainActor () -> SystemPermissions.LoginItemStatus
        var setLaunchAtLogin: @MainActor (Bool) throws -> Void
        var openLoginItemsSettings: @MainActor () -> Void

        static var system: Permissions {
            Permissions(
                isAccessibilityTrusted: { SystemPermissions.isAccessibilityTrusted },
                requestAccessibility: { SystemPermissions.requestAccessibility() },
                openAccessibilitySettings: { SystemPermissions.openAccessibilitySettings() },
                loginItemStatus: { SystemPermissions.loginItemStatus },
                setLaunchAtLogin: { try SystemPermissions.setLaunchAtLogin($0) },
                openLoginItemsSettings: { SystemPermissions.openLoginItemsSettings() }
            )
        }
    }

    private(set) var step: Step = .welcome
    private(set) var isAccessibilityTrusted = false
    private(set) var loginItemStatus: SystemPermissions.LoginItemStatus = .notRegistered
    private(set) var loginItemFailure: String?
    private(set) var isFinished = false
    /// Called once when the onboarding ends; the window controller closes the window.
    @ObservationIgnored var onFinish: (@MainActor () -> Void)?
    /// Called when 권한 열기 or 설정 열기 sends the user to System Settings.
    @ObservationIgnored var onOpenSystemSettings: (@MainActor () -> Void)?
    /// Called when a permission turns on while the 권한 step shows, also when that happened in
    /// System Settings.
    @ObservationIgnored var onPermissionGranted: (@MainActor () -> Void)?

    var accessibilityState: PermissionState { .accessibility(trusted: isAccessibilityTrusted) }
    var loginItemState: PermissionState { .loginItem(loginItemStatus, failure: loginItemFailure) }
    var isLastStep: Bool { step == Step.allCases.last }

    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let record: OnboardingRecord
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let grantPause: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var autoAdvance: Task<Void, Never>?

    /// `grantPause` is how long both checked cards stay on screen before the 권한 step moves on by itself.
    init(
        permissions: Permissions = .system,
        record: OnboardingRecord,
        pollInterval: Duration = .milliseconds(500),
        grantPause: Duration = .milliseconds(900)
    ) {
        self.permissions = permissions
        self.record = record
        self.pollInterval = pollInterval
        self.grantPause = grantPause
    }

    /// Starts following the permissions; the window calls it when it opens.
    func start() {
        guard pollTask == nil, !isFinished else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    /// What Enter (계속, 시작하기 on the last step) and Esc (나중에) both do: go to the next step, or
    /// end the onboarding on the last one. Neither turns a permission on; a skipped item stays as it
    /// is and is turned on later in Settings.
    func advance() {
        if isLastStep {
            finish()
        } else {
            next()
        }
    }

    /// Shows the system prompt, which adds the app to the Accessibility list, and opens that list.
    func requestAccessibility() {
        permissions.requestAccessibility()
        permissions.openAccessibilitySettings()
        onOpenSystemSettings?()
    }

    func enableLaunchAtLogin() {
        let before = permissionsOn
        do {
            try permissions.setLaunchAtLogin(true)
            loginItemFailure = nil
        } catch {
            loginItemFailure = SystemPermissions.launchAtLoginFailure(enabling: true, error)
        }
        loginItemStatus = permissions.loginItemStatus()
        noticeGrant(since: before)
    }

    /// For 허용 필요: the login item is registered and waits for the user in System Settings.
    func openLoginItemsSettings() {
        permissions.openLoginItemsSettings()
        onOpenSystemSettings?()
    }

    /// Ends the onboarding and marks it completed: 시작하기 and the user closing the window both
    /// count, quitting the app does not. Only the first call does anything.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        pollTask?.cancel()
        pollTask = nil
        autoAdvance?.cancel()
        autoAdvance = nil
        record.markCompleted()
        onFinish?()
    }

    private func next() {
        guard let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count else { return }
        autoAdvance?.cancel()
        autoAdvance = nil
        step = Step.allCases[index + 1]
        if step == .permissions { readPermissions() }
    }

    /// What the 권한 step shows when it comes up. Permissions that are on already just show checked;
    /// only a grant made while the step shows moves on by itself.
    private func readPermissions() {
        isAccessibilityTrusted = permissions.isAccessibilityTrusted()
        loginItemStatus = permissions.loginItemStatus()
    }

    private func refresh() {
        guard step == .permissions else { return }
        let before = permissionsOn
        readPermissions()
        noticeGrant(since: before)
    }

    private var permissionsOn: (accessibility: Bool, loginItem: Bool) {
        (isAccessibilityTrusted, loginItemStatus == .enabled)
    }

    /// A permission that just turned on brings the window back; once both are on, the step moves on
    /// after `grantPause`, so the user sees both checks first.
    private func noticeGrant(since before: (accessibility: Bool, loginItem: Bool)) {
        let now = permissionsOn
        guard step == .permissions,
              (!before.accessibility && now.accessibility) || (!before.loginItem && now.loginItem) else { return }
        onPermissionGranted?()
        guard now.accessibility, now.loginItem, autoAdvance == nil else { return }
        autoAdvance = Task { [weak self, grantPause] in
            try? await Task.sleep(for: grantPause)
            guard let self, !Task.isCancelled, self.step == .permissions else { return }
            self.next()
        }
    }
}
