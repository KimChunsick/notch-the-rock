import Foundation
import NotchKit
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

/// The onboarding steps, the permissions they turn on and the plugins' setup steps. The window only
/// draws `step` and calls these methods. While the window is up (`start()` to `finish()`) the model follows both permissions
/// on the 권한 step every `pollInterval`, so a grant made in System Settings shows without a relaunch.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Hashable {
        case welcome
        case permissions
        /// A plugin's setup step, by plugin identifier.
        case setup(String)
        case usage
        case done
    }

    /// An enabled plugin's setup step: its symbol for the cards without an icon, and what it offers.
    struct PluginSetupStep {
        let pluginID: String
        let symbol: String
        let setup: PluginSetup
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

        /// The card for this state; `action` is what the button says while the permission is off.
        func card(action: String) -> OnboardingCard {
            switch self {
            case .off: OnboardingCard(.action(action))
            case .on: OnboardingCard(.done(label))
            case .needsApproval: OnboardingCard(.attention(label, action: "설정 열기"))
            case .failed(let reason): OnboardingCard(.action("다시 시도"), failure: reason)
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

    /// Welcome, 권한, one step per enabled plugin that offers setup, 사용법 and the last step.
    let steps: [Step]
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
    var isLastStep: Bool { step == steps.last }

    @ObservationIgnored private let setups: [PluginSetupStep]
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
        setups: [PluginSetupStep] = [],
        pollInterval: Duration = .milliseconds(500),
        grantPause: Duration = .milliseconds(900)
    ) {
        steps = [.welcome, .permissions] + setups.map { .setup($0.pluginID) } + [.usage, .done]
        self.setups = setups
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
    /// end the onboarding on the last one. Neither turns a permission on nor sets up a plugin's item;
    /// a skipped item stays as it is and is turned on or connected later in Settings.
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
        noticeChange(since: before)
    }

    /// For 허용 필요: the login item is registered and waits for the user in System Settings.
    func openLoginItemsSettings() {
        permissions.openLoginItemsSettings()
        onOpenSystemSettings?()
    }

    func setup(for pluginID: String) -> PluginSetupStep? {
        setups.first { $0.pluginID == pluginID }
    }

    /// The 연결 (or 다시 시도) button of a setup card: the only way an item is set up here. A card
    /// that shows no button (working, connected, unavailable) ignores it.
    func performSetup(_ item: PluginSetupItem) {
        guard OnboardingCard(setup: item.state).status.offersAction else { return }
        item.perform()
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
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        autoAdvance?.cancel()
        autoAdvance = nil
        step = steps[index + 1]
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
        noticeChange(since: before)
    }

    private var permissionsOn: (accessibility: Bool, loginItem: Bool) {
        (isAccessibilityTrusted, loginItemStatus == .enabled)
    }

    /// A permission that just turned on brings the window back; once both are on, the step moves on
    /// after `grantPause`, so the user sees both checks first. A permission that is off stops that
    /// pause, and the step reads both again before moving on, so it never leaves one off behind the
    /// user's back; the next grant starts a new pause.
    private func noticeChange(since before: (accessibility: Bool, loginItem: Bool)) {
        let now = permissionsOn
        guard step == .permissions else { return }
        if !now.accessibility || !now.loginItem {
            autoAdvance?.cancel()
            autoAdvance = nil
        }
        guard (!before.accessibility && now.accessibility) || (!before.loginItem && now.loginItem) else { return }
        onPermissionGranted?()
        guard now.accessibility, now.loginItem, autoAdvance == nil else { return }
        autoAdvance = Task { [weak self, grantPause] in
            try? await Task.sleep(for: grantPause)
            guard let self, !Task.isCancelled, self.step == .permissions else { return }
            // Polling may not have seen a permission turned off late in the pause.
            self.readPermissions()
            let now = self.permissionsOn
            guard now.accessibility, now.loginItem else {
                self.autoAdvance = nil
                return
            }
            self.next()
        }
    }
}

/// What a card on the 권한 step or on a plugin's setup step shows: one card for both, so the same
/// status looks the same on either step.
struct OnboardingCard: Equatable {
    enum Status: Equatable {
        /// The button only.
        case action(String)
        /// The animated check and the label.
        case done(String)
        /// The label in the attention colour, then the button.
        case attention(String, action: String)
        /// A spinner and the label, no button.
        case progress(String)
        /// The text instead of a button.
        case note(String)

        var offersAction: Bool {
            switch self {
            case .action, .attention: true
            case .done, .progress, .note: false
            }
        }
    }

    let status: Status
    /// Shown in place of the detail line, in the failure colour.
    let failure: String?

    init(_ status: Status, failure: String? = nil) {
        self.status = status
        self.failure = failure
    }

    /// A plugin's setup item: 연결 until it is connected, the reason instead of the button when it
    /// cannot be set up here, 다시 시도 under a failure.
    init(setup state: PluginSetupState) {
        switch state {
        case .notConnected: self.init(.action("연결"))
        case .working: self.init(.progress("연결 중"))
        case .connected: self.init(.done("연결됨"))
        case .unavailable(let reason): self.init(.note(reason))
        case .failed(let message): self.init(.action("다시 시도"), failure: message)
        @unknown default: self.init(.note("설정에서 확인해 주세요"))
        }
    }
}
