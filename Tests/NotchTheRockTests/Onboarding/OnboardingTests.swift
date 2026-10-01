import AppKit
import Testing
@testable import NotchTheRock

/// Stands in for `SystemPermissions`: the tests flip the Accessibility grant and the login item.
@MainActor
private final class FakePermissions {
    var trusted = false
    var status: SystemPermissions.LoginItemStatus = .notRegistered
    var registerError: (any Error)?
    var calls: [String] = []

    var permissions: OnboardingModel.Permissions {
        OnboardingModel.Permissions(
            isAccessibilityTrusted: { self.trusted },
            requestAccessibility: { self.calls.append("prompt") },
            openAccessibilitySettings: { self.calls.append("accessibility settings") },
            loginItemStatus: { self.status },
            setLaunchAtLogin: { enabled in
                if let error = self.registerError { throw error }
                self.status = enabled ? .enabled : .notRegistered
            },
            openLoginItemsSettings: { self.calls.append("login items settings") }
        )
    }
}

@MainActor
@Suite struct OnboardingTests {
    private let suiteName = "OnboardingTests.\(UUID().uuidString)"

    private func withRecord(_ body: (OnboardingRecord) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(OnboardingRecord(defaults: defaults))
    }

    /// Waits until `condition` holds, giving the model's poll and pause tasks main-actor turns in
    /// between. The bound counts turns, not wall time: the suites share the one main actor, and a
    /// render test elsewhere can hold it for seconds, which a clock deadline would count against
    /// the model.
    private func waitUntil(_ condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 300 {
            try? await Task.sleep(for: .milliseconds(10))
            turns += 1
        }
    }

    @Test func R13__first_launch_shows_onboarding_and_a_completed_mark_hides_it() {
        withRecord { record in
            #expect(record.showsAtLaunch(arguments: []))
            record.markCompleted()
            #expect(!record.showsAtLaunch(arguments: []))
        }
    }

    @Test func R13__skip_onboarding_hides_it_without_marking_it_completed() {
        withRecord { record in
            #expect(!record.showsAtLaunch(arguments: ["--skip-onboarding"]))
            #expect(!record.isCompleted)
            #expect(record.showsAtLaunch(arguments: []))
        }
    }

    @Test func R13__reset_onboarding_clears_the_completed_mark() {
        withRecord { record in
            record.markCompleted()
            #expect(record.showsAtLaunch(arguments: ["--reset-onboarding"]))
            #expect(!record.isCompleted)
            record.markCompleted()
            #expect(!record.showsAtLaunch(arguments: ["--reset-onboarding", "--skip-onboarding"]))
            #expect(!record.isCompleted)
        }
    }

    /// Granting a permission while the 권한 step shows is noticed at once and brings the window back;
    /// once both are on the step moves on by itself. The 로그인 card is not skipped: an Accessibility
    /// grant alone keeps the step up.
    @Test func R13__a_grant_on_the_permission_step_is_noticed_and_both_on_moves_on_by_itself() async {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = FakePermissions()
        let model = OnboardingModel(
            permissions: fake.permissions,
            record: OnboardingRecord(defaults: defaults),
            pollInterval: .milliseconds(10),
            grantPause: .milliseconds(10)
        )
        var steppedAside = 0
        var granted = 0
        model.onOpenSystemSettings = { steppedAside += 1 }
        model.onPermissionGranted = { granted += 1 }
        model.start()
        model.advance()
        #expect(model.step == .permissions)
        model.requestAccessibility()
        #expect(fake.calls == ["prompt", "accessibility settings"])
        #expect(steppedAside == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.step == .permissions, "moved on before Accessibility was granted")
        #expect(granted == 0)

        fake.trusted = true
        await waitUntil { model.accessibilityState == .on }
        #expect(model.accessibilityState == .on)
        #expect(granted == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.step == .permissions, "the 로그인 시 자동 실행 card is still off")

        model.enableLaunchAtLogin()
        #expect(model.loginItemState == .on)
        #expect(granted == 2)
        await waitUntil { model.step != .permissions }
        #expect(model.step == .usage)
        model.finish()
    }

    /// Both cards checked wait `grantPause` before the step moves on. A permission turned off in that
    /// pause keeps the 권한 step up with its card off; turning it on again moves on after a new pause.
    @Test func R13__turning_a_permission_off_during_the_pause_keeps_the_permissions_step() async {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = FakePermissions()
        let model = OnboardingModel(
            permissions: fake.permissions,
            record: OnboardingRecord(defaults: defaults),
            pollInterval: .milliseconds(10),
            grantPause: .milliseconds(100)
        )
        model.start()
        model.advance()
        fake.trusted = true
        await waitUntil { model.accessibilityState == .on }
        #expect(model.accessibilityState == .on)

        model.enableLaunchAtLogin()
        fake.trusted = false
        await waitUntil { model.accessibilityState == .off }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.step == .permissions, "Accessibility was turned off during the pause")
        #expect(model.accessibilityState == .off)
        #expect(model.loginItemState == .on)

        fake.trusted = true
        await waitUntil { model.step != .permissions }
        #expect(model.step == .usage)
        model.finish()
    }

    /// Right before moving on the step reads both permissions again, so one turned off after the
    /// last poll keeps it up too; a grant after that starts the pause again.
    @Test func R13__moving_on_reads_both_permissions_again_first() async {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = FakePermissions()
        fake.trusted = true
        let model = OnboardingModel(
            permissions: fake.permissions,
            record: OnboardingRecord(defaults: defaults),
            pollInterval: .milliseconds(300),
            grantPause: .milliseconds(10)
        )
        model.start()
        model.advance()
        #expect(model.accessibilityState == .on)
        model.enableLaunchAtLogin()
        #expect(model.loginItemState == .on)
        // Turned off before the first poll: only the read at the end of the pause can see it.
        fake.trusted = false
        await waitUntil { model.accessibilityState == .off }
        #expect(model.accessibilityState == .off)
        #expect(model.step == .permissions)

        fake.trusted = true
        await waitUntil { model.step != .permissions }
        #expect(model.step == .usage)
        model.finish()
    }

    @Test func R13__login_item_status_is_shown_in_korean() {
        let labels = [SystemPermissions.LoginItemStatus.enabled, .requiresApproval, .notRegistered, .notFound].map(\.label)
        // Before the first registration the system reports `.notFound`; that is "off", not an error.
        #expect(labels == ["켜져 있어요", "시스템 설정의 로그인 항목에서 허용해야 해요", "꺼져 있어요", "꺼져 있어요"])

        withRecord { record in
            let fake = FakePermissions()
            let model = OnboardingModel(permissions: fake.permissions, record: record, pollInterval: .seconds(60))
            model.advance()
            #expect(model.step == .permissions)

            fake.registerError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "테스트 오류"])
            model.enableLaunchAtLogin()
            #expect(model.loginItemFailure == "로그인 항목을 등록하지 못했어요: 테스트 오류")
            #expect(model.loginItemState == .failed("로그인 항목을 등록하지 못했어요: 테스트 오류"))

            fake.registerError = nil
            model.enableLaunchAtLogin()
            #expect(model.loginItemFailure == nil)
            #expect(model.loginItemState == .on)
            #expect(model.loginItemState.label == "켜짐")
        }
    }

    /// Opening the running app again always shows Settings; this launch's onboarding comes forward
    /// with it only while its window is open and unfinished.
    @Test func R13__reopening_always_shows_settings_and_brings_back_an_unfinished_onboarding() {
        withRecord { record in
            let model = OnboardingModel(permissions: FakePermissions().permissions, record: record)
            #expect(ReopenWindows.of(onboarding: model, onboardingWindowIsOpen: true) == [.settings, .onboarding])
            #expect(ReopenWindows.of(onboarding: model, onboardingWindowIsOpen: false) == [.settings], "during the greeting")
            model.finish()
            #expect(ReopenWindows.of(onboarding: model, onboardingWindowIsOpen: false) == [.settings], "onboarding finished")

            // A launch after completion, or with --skip-onboarding, has no onboarding.
            #expect(!record.showsAtLaunch(arguments: []), "completed")
            #expect(ReopenWindows.of(onboarding: nil, onboardingWindowIsOpen: false) == [.settings])
            record.defaults.removeObject(forKey: OnboardingRecord.completedKey)
            #expect(!record.showsAtLaunch(arguments: ["--skip-onboarding"]))
            #expect(ReopenWindows.of(onboarding: nil, onboardingWindowIsOpen: false) == [.settings])
        }
    }

    /// Another app's window must not bury the onboarding: there is no Dock icon, app switcher entry
    /// or menu bar icon to bring it back. Settings stays an ordinary window the gear reopens.
    @Test func R13__app_windows_stay_up_when_another_app_is_used() {
        withRecord { record in
            let onboarding = OnboardingWindowController(model: OnboardingModel(permissions: FakePermissions().permissions, record: record))
                .makeWindow()
            #expect(onboarding.level == .floating)
            #expect(!onboarding.hidesOnDeactivate)

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
            defer { try? FileManager.default.removeItem(at: directory) }
            let locations = PluginLocations(
                builtIn: nil,
                user: directory.appendingPathComponent("Plugins"),
                cache: directory.appendingPathComponent("PluginCache"),
                data: directory.appendingPathComponent("PluginData"),
                storagePrefix: suiteName
            )
            let catalog = PluginCatalog(host: NotchHostModel(), locations: locations, defaults: record.defaults)
            let settings = SettingsWindowController(catalog: catalog).makeWindow()
            #expect(settings.level == .normal)
            #expect(!settings.hidesOnDeactivate)
        }
    }

    @Test func R13__finishing_or_closing_marks_it_completed_once() {
        withRecord { record in
            let model = OnboardingModel(permissions: FakePermissions().permissions, record: record)
            var finished = 0
            model.onFinish = { finished += 1 }
            model.finish()
            model.finish()
            #expect(model.isFinished)
            #expect(finished == 1)
            #expect(record.isCompleted)
            #expect(!record.showsAtLaunch(arguments: []))
        }
    }

    /// Quitting or logging out while the onboarding is open closes its window too; only the user
    /// finishing it or closing the window may mark it completed.
    @Test func R13__quitting_the_app_mid_onboarding_does_not_mark_it_completed() {
        withRecord { record in
            let model = OnboardingModel(permissions: FakePermissions().permissions, record: record)
            let controller = OnboardingWindowController(model: model)
            let window = controller.makeWindow()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            window.close()
            #expect(!model.isFinished)
            #expect(!record.isCompleted)
            #expect(record.showsAtLaunch(arguments: []))

            let closedByUser = OnboardingModel(permissions: FakePermissions().permissions, record: record)
            let otherController = OnboardingWindowController(model: closedByUser)
            otherController.makeWindow().close()
            #expect(closedByUser.isFinished)
            #expect(record.isCompleted)
        }
    }

    /// No title bar or traffic lights, a rounded dark translucent background whatever the system
    /// appearance, and it still becomes key so Enter and Esc reach it. It is sized before it is
    /// centred, so it opens in the middle of the screen.
    @Test func R14__window_is_a_borderless_dark_translucent_panel_that_takes_the_keyboard() throws {
        try withRecord { record in
            let window = OnboardingWindowController(model: OnboardingModel(permissions: FakePermissions().permissions, record: record))
                .makeWindow()
            #expect(!window.styleMask.contains(.titled))
            #expect(window.canBecomeKey)
            #expect(window.level == .floating)
            #expect(!window.hidesOnDeactivate)
            #expect(window.isMovableByWindowBackground)
            #expect(!window.isOpaque)
            #expect(window.backgroundColor == .clear)
            #expect(window.hasShadow)
            #expect(window.appearance?.name == .darkAqua)

            let background = try #require(window.contentView as? NSVisualEffectView)
            #expect(background.blendingMode == .behindWindow)
            #expect(background.state == .active)
            #expect(background.maskImage != nil, "rounded corners")

            #expect(window.frame.size == OnboardingWindowController.size)
            if let screen = NSScreen.main {
                #expect(abs(window.frame.midX - screen.visibleFrame.midX) < 1, "centred, not its corner at the centre")
            }
        }
    }

    /// Enter (계속, then 시작하기) and Esc (나중에) both call `advance()`: pressing either alone goes
    /// through the four steps in order and completes, and neither turns a permission on.
    @Test func R14__enter_or_esc_alone_reaches_the_end_without_turning_anything_on() {
        withRecord { record in
            let fake = FakePermissions()
            let model = OnboardingModel(permissions: fake.permissions, record: record, pollInterval: .seconds(60))
            var finished = 0
            model.onFinish = { finished += 1 }
            var visited = [model.step]
            while !model.isFinished, visited.count < 10 {
                model.advance()
                if !model.isFinished { visited.append(model.step) }
            }
            #expect(visited == [.welcome, .permissions, .usage, .done])
            #expect(model.isFinished)
            #expect(finished == 1)
            #expect(record.isCompleted)
            #expect(fake.calls.isEmpty)
            #expect(model.accessibilityState == .off)
            #expect(model.loginItemState == .off)
            #expect(fake.status == .notRegistered)
        }
    }

    /// Each card shows off, on (checked), 허용 필요 or the error. Permissions that are on when the step
    /// comes up show checked and the step waits for Enter; only a grant made meanwhile moves on.
    @Test func R14__permission_cards_show_off_on_needs_approval_and_error() async {
        typealias State = OnboardingModel.PermissionState
        #expect(State.accessibility(trusted: false) == .off)
        #expect(State.accessibility(trusted: true) == .on)
        #expect(State.loginItem(.enabled, failure: nil) == .on)
        #expect(State.loginItem(.requiresApproval, failure: nil) == .needsApproval)
        #expect(State.loginItem(.notRegistered, failure: nil) == .off)
        #expect(State.loginItem(.notFound, failure: nil) == .off)
        #expect(State.loginItem(.notFound, failure: "로그인 항목을 등록하지 못했어요: 오류") == .failed("로그인 항목을 등록하지 못했어요: 오류"))
        #expect(State.loginItem(.enabled, failure: "이전 오류") == .on)
        #expect([State.off, .on, .needsApproval, .failed("오류")].map(\.label) == ["꺼짐", "켜짐", "허용 필요", "오류"])

        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = FakePermissions()
        fake.trusted = true
        fake.status = .requiresApproval
        let model = OnboardingModel(
            permissions: fake.permissions,
            record: OnboardingRecord(defaults: defaults),
            pollInterval: .milliseconds(10),
            grantPause: .milliseconds(10)
        )
        var granted = 0
        model.onPermissionGranted = { granted += 1 }
        model.start()
        model.advance()
        #expect(model.accessibilityState == .on)
        #expect(model.loginItemState == .needsApproval)
        model.openLoginItemsSettings()
        #expect(fake.calls == ["login items settings"])

        fake.status = .enabled
        await waitUntil { model.step != .permissions }
        #expect(granted == 1, "allowed in System Settings")
        #expect(model.step == .usage)
        model.finish()

        let alreadyOn = OnboardingModel(
            permissions: fake.permissions,
            record: OnboardingRecord(defaults: defaults),
            pollInterval: .milliseconds(10),
            grantPause: .milliseconds(10)
        )
        alreadyOn.onPermissionGranted = { granted += 1 }
        alreadyOn.start()
        alreadyOn.advance()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(alreadyOn.step == .permissions, "already on: the checked cards wait for Enter")
        #expect(alreadyOn.accessibilityState == .on)
        #expect(alreadyOn.loginItemState == .on)
        #expect(granted == 1)
        alreadyOn.finish()
    }

    /// The floating window would cover the System Settings switch the user has to flip: it drops to
    /// the normal level when 권한 열기 or 설정 열기 sends the user there. A grant (or a reopen) brings it
    /// back through `bringForward()`, which floats it again; so does the user clicking the window.
    @Test func R14__sending_the_user_to_system_settings_steps_the_window_aside() {
        withRecord { record in
            let fake = FakePermissions()
            fake.status = .requiresApproval
            let model = OnboardingModel(permissions: fake.permissions, record: record, pollInterval: .seconds(60))
            let controller = OnboardingWindowController(model: model)
            let window = controller.makeWindow()
            #expect(window.level == .floating)
            model.advance()
            model.requestAccessibility()
            #expect(window.level == .normal)
            #expect(model.onPermissionGranted != nil, "a grant brings the window back")
            controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            #expect(window.level == .floating)

            model.openLoginItemsSettings()
            #expect(window.level == .normal)
            #expect(fake.calls == ["prompt", "accessibility settings", "login items settings"])
        }
    }
}
