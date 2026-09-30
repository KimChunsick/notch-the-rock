import Foundation
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

    @Test func R13__granting_accessibility_moves_on_to_launch_at_login_by_itself() async {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fake = FakePermissions()
        let model = OnboardingModel(
            permissions: fake.permissions,
            record: OnboardingRecord(defaults: defaults),
            pollInterval: .milliseconds(10)
        )
        model.start()
        model.next()
        #expect(model.step == .accessibility)
        model.requestAccessibility()
        #expect(fake.calls == ["prompt", "accessibility settings"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.step == .accessibility, "moved on before Accessibility was granted")

        fake.trusted = true
        let deadline = ContinuousClock.now + .seconds(2)
        while model.step == .accessibility, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.step == .launchAtLogin)
        #expect(model.isAccessibilityTrusted)
        model.finish()
    }

    @Test func R13__login_item_status_is_shown_in_korean() {
        let labels = [SystemPermissions.LoginItemStatus.enabled, .requiresApproval, .notRegistered, .notFound].map(\.label)
        // Before the first registration the system reports `.notFound`; that is "off", not an error.
        #expect(labels == ["켜져 있어요", "시스템 설정의 로그인 항목에서 허용해야 해요", "꺼져 있어요", "꺼져 있어요"])

        withRecord { record in
            let fake = FakePermissions()
            fake.trusted = true
            let model = OnboardingModel(permissions: fake.permissions, record: record, pollInterval: .seconds(60))
            model.next()
            #expect(model.step == .launchAtLogin, "an already granted Accessibility step is passed over")

            fake.registerError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "테스트 오류"])
            model.enableLaunchAtLogin()
            #expect(model.loginItemFailure == "로그인 항목을 등록하지 못했어요: 테스트 오류")
            #expect(model.loginItemStatus == .notRegistered)

            fake.registerError = nil
            model.enableLaunchAtLogin()
            #expect(model.loginItemFailure == nil)
            #expect(model.loginItemStatus == .enabled)
            #expect(model.loginItemStatus.label == "켜져 있어요")
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
}
