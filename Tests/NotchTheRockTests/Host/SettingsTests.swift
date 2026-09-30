import Foundation
import ServiceManagement
import Testing
@testable import NotchTheRock

private final class TestBundleMarker {}

@MainActor
@Suite struct SettingsTests {
    /// The milestone check runs the built app with `--print-permissions`: two lines on stdout, exit 0,
    /// and no notch window (the process ends by itself).
    @Test func R01__print_permissions_prints_both_lines_and_exits_without_ui() async throws {
        let app = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("NotchTheRock")
        let process = Process()
        process.executableURL = app
        process.arguments = ["--print-permissions"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(20)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let finished = !process.isRunning
        if !finished { process.terminate() }
        #expect(finished, "--print-permissions kept running (it started the app instead of printing)")
        guard finished else { return }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(process.terminationStatus == 0)
        #expect(lines.count == 2)
        #expect(["accessibility=trusted", "accessibility=untrusted"].contains(lines.first))
        #expect(lines.dropFirst().first.map { $0.hasPrefix("login-item=") } == true)
    }

    /// R04's check reads `login-item=enabled`: each `SMAppService.Status` has one fixed spelling.
    @Test func R04__login_item_status_is_printed_with_a_fixed_spelling() {
        let spellings = [SMAppService.Status.enabled, .requiresApproval, .notRegistered, .notFound]
            .map { SystemPermissions.LoginItemStatus($0).rawValue }
        #expect(spellings == ["enabled", "requiresApproval", "notRegistered", "notFound"])
        #expect(SystemPermissions.LoginItemStatus.enabled.isRegistered)
        #expect(SystemPermissions.LoginItemStatus.requiresApproval.isRegistered)
        #expect(!SystemPermissions.LoginItemStatus.notRegistered.isRegistered)
    }

    /// The plugin list says whether each plugin is on, off, waiting for consent or refused and why,
    /// and when a change applies only after a relaunch.
    @Test func R03__plugin_rows_show_the_state_and_its_reason() {
        func record(_ state: PluginRecord.State, needsRestart: Bool = false) -> PluginRecord {
            var record = PluginRecord(
                bundleURL: URL(fileURLWithPath: "/tmp/Sample.notchplugin"),
                source: .user,
                identifier: "com.example.sample",
                name: "Sample",
                version: "1.0.0",
                fingerprint: nil,
                state: state
            )
            record.needsRestart = needsRestart
            return record
        }
        #expect(record(.on).stateText == "켜짐")
        #expect(record(.off).stateText == "꺼짐")
        #expect(record(.needsConsent(PluginCatalog.changedReason)).stateText == "허락 필요: \(PluginCatalog.changedReason)")
        #expect(record(.failed("진입 함수를 찾지 못했어요")).stateText == "오류: 진입 함수를 찾지 못했어요")
        #expect(record(.on, needsRestart: true).stateText == "켜짐 · 앱을 다시 켜야 적용돼요")
        #expect(PluginRecord.Source.builtIn.label == "내장")
        #expect(PluginRecord.Source.user.label == "사용자")
    }
}
