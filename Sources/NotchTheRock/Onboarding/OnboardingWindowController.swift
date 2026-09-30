import AppKit
import OSLog
import SwiftUI

/// The first-launch onboarding window. It opens after the notch's greeting so it never covers it,
/// and closing it counts as finishing. It floats above other apps' windows until then: once the
/// user clicks another app, an ordinary window of this accessory app ends up behind that app's
/// windows, with no Dock icon or app switcher entry to bring it back.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?
    private let logger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "onboarding")

    init(model: OnboardingModel) {
        self.model = model
        super.init()
        model.onFinish = { [weak self] in self?.window?.close() }
    }

    /// Opens the window once `isGreeting` turns false, or after `limit` at the latest.
    func show(after isGreeting: @escaping @MainActor () -> Bool, limit: Duration = .milliseconds(3500)) {
        Task {
            let start = ContinuousClock.now
            while isGreeting(), ContinuousClock.now - start < limit {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let reason = isGreeting() ? "the wait limit, greeting still showing" : "the greeting ended"
            logger.notice("onboarding window opened after \(reason, privacy: .public) (\(ContinuousClock.now - start, privacy: .public) after plugins loaded)")
            present()
        }
    }

    private func present() {
        let window = makeWindow()
        self.window = window
        model.start()
        window.showInFront()
    }

    /// Brings the open window back to the front, for a reopen of the running app. During the
    /// greeting there is no window yet; it opens by itself when the greeting ends.
    func bringForward() {
        guard let window else {
            logger.notice("reopened during the greeting; the onboarding window opens when it ends")
            return
        }
        window.showInFront()
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model)))
        window.title = "NotchTheRock 시작하기"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the window first: finish() calls onFinish, which would close it a second time.
        window?.delegate = nil
        window = nil
        model.finish()
        logger.notice("onboarding completed")
    }
}

/// Four calm steps; every action goes through the model.
struct OnboardingView: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            Spacer(minLength: 0)
            HStack {
                Text("\(stepNumber) / \(OnboardingModel.Step.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 460, height: 300)
    }

    private var stepNumber: Int {
        (OnboardingModel.Step.allCases.firstIndex(of: model.step) ?? 0) + 1
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            header("macbook", "NotchTheRock을 시작해요")
            Text("노치가 배터리 같은 소식을 보여 주고, 포인터를 올리면 펼쳐져요. 설정은 노치에 포인터를 올린 뒤 톱니바퀴를 누르거나, 노치를 오른쪽 클릭해 설정…을 고르면 열 수 있어요.")
                .foregroundStyle(.secondary)
        case .accessibility:
            header("accessibility", "손쉬운 사용 권한")
            Text("볼륨·밝기 키를 노치에서 보여주려면 필요해요. 버튼을 누르면 시스템 설정의 손쉬운 사용 목록이 열려요. 거기서 NotchTheRock을 켜 주세요.")
                .foregroundStyle(.secondary)
            if model.isAccessibilityTrusted {
                Label("허용됐어요", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("허용하면 바로 알아채고 다음 단계로 넘어가요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .launchAtLogin:
            header("power", "로그인 시 자동 실행")
            Text("Mac에 로그인하면 NotchTheRock이 저절로 켜져요.")
                .foregroundStyle(.secondary)
            LabeledContent("상태", value: model.loginItemStatus.label)
            if model.loginItemStatus == .requiresApproval {
                Button("로그인 항목 설정 열기") { model.openLoginItemsSettings() }
            }
            if let failure = model.loginItemFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        case .done:
            header("checkmark.circle", "준비가 끝났어요")
            Text("건너뛴 항목은 설정에서 언제든 켤 수 있어요. 손쉬운 사용은 권한 탭에, 로그인 시 자동 실행은 일반 탭에 있어요.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.step {
        case .welcome:
            Button("다음") { model.next() }
                .keyboardShortcut(.defaultAction)
        case .accessibility:
            Button("나중에 할게요") { model.next() }
            Button("시스템 설정 열기") { model.requestAccessibility() }
                .keyboardShortcut(.defaultAction)
        case .launchAtLogin:
            if model.loginItemStatus.isRegistered {
                Button("다음") { model.next() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("나중에 할게요") { model.next() }
                Button("자동 실행 켜기") { model.enableLaunchAtLogin() }
                    .keyboardShortcut(.defaultAction)
            }
        case .done:
            Button("완료") { model.finish() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func header(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.semibold))
        }
    }
}
