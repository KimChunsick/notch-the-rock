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
/// these methods. While the window is up (`start()` to `finish()`) the model follows the permission
/// of the visible step every `pollInterval`, so a grant made in System Settings shows without a
/// relaunch and a granted Accessibility moves on by itself.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: CaseIterable {
        case welcome
        case accessibility
        case launchAtLogin
        case done
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

    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let record: OnboardingRecord
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(permissions: Permissions = .system, record: OnboardingRecord, pollInterval: Duration = .milliseconds(500)) {
        self.permissions = permissions
        self.record = record
        self.pollInterval = pollInterval
    }

    /// Starts following the visible step's permission; the window calls it when it opens.
    func start() {
        guard pollTask == nil, !isFinished else { return }
        refresh()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    /// Goes to the next step. 나중에 할게요 does the same, so a skipped item stays as it is and is
    /// turned on later in Settings.
    func next() {
        guard let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count else { return }
        step = Step.allCases[index + 1]
        refresh()
    }

    /// Shows the system prompt, which adds the app to the Accessibility list, and opens that list.
    func requestAccessibility() {
        permissions.requestAccessibility()
        permissions.openAccessibilitySettings()
    }

    func enableLaunchAtLogin() {
        do {
            try permissions.setLaunchAtLogin(true)
            loginItemFailure = nil
        } catch {
            loginItemFailure = SystemPermissions.launchAtLoginFailure(enabling: true, error)
        }
        loginItemStatus = permissions.loginItemStatus()
    }

    func openLoginItemsSettings() {
        permissions.openLoginItemsSettings()
    }

    /// Ends the onboarding and marks it completed: 완료 and closing the window both count. Only the
    /// first call does anything.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        pollTask?.cancel()
        pollTask = nil
        record.markCompleted()
        onFinish?()
    }

    /// Reads the permission of the visible step. A granted Accessibility moves on by itself, also
    /// when it was granted before the step came up.
    private func refresh() {
        switch step {
        case .accessibility:
            isAccessibilityTrusted = permissions.isAccessibilityTrusted()
            if isAccessibilityTrusted { next() }
        case .launchAtLogin:
            loginItemStatus = permissions.loginItemStatus()
        case .welcome, .done:
            break
        }
    }
}
