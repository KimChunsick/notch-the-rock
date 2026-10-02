import AppKit
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A tool a fake plugin offers to connect: counts presses, and a press connects it.
@MainActor
@Observable
private final class FakeTool {
    var state: PluginSetupState
    var performed = 0
    let id: String
    let title: String

    init(_ id: String, title: String, state: PluginSetupState = .notConnected) {
        self.id = id
        self.title = title
        self.state = state
    }

    var item: PluginSetupItem {
        PluginSetupItem(id: id, title: title, detail: "\(title) 작업을 노치에서 알려 줘요", state: { self.state }, perform: {
            self.performed += 1
            self.state = .connected
        })
    }
}

/// A plugin offering the two fake tools as its onboarding step.
@MainActor
private final class SetupPlugin: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.setup", name: "Setup", version: "1.0.0", symbol: "terminal.fill", sdkVersion: NotchKitSDK.version)
    static var tools: [FakeTool] = []

    init(context: NotchContext) {}
    func activate() {}
    func deactivate() {}

    var setup: PluginSetup? {
        PluginSetup(title: "코딩 에이전트 연결", message: "작업이 끝나면 노치가 알려 줘요.", items: Self.tools.map(\.item))
    }
}

@MainActor
@Suite struct OnboardingSetupTests {
    private let suiteName = "OnboardingSetupTests.\(UUID().uuidString)"
    private static let pluginID = "com.example.agents"

    private func model(_ tools: [FakeTool], defaults: UserDefaults) -> OnboardingModel {
        let setup = PluginSetup(title: "코딩 에이전트 연결", message: "작업이 끝나면 노치가 알려 줘요.", items: tools.map(\.item))
        return OnboardingModel(
            permissions: OnboardingModel.Permissions(
                isAccessibilityTrusted: { false }, requestAccessibility: {}, openAccessibilitySettings: {},
                loginItemStatus: { .notRegistered }, setLaunchAtLogin: { _ in }, openLoginItemsSettings: {}
            ),
            record: OnboardingRecord(defaults: defaults),
            setups: setup.map { [OnboardingModel.PluginSetupStep(pluginID: Self.pluginID, symbol: "terminal.fill", setup: $0)] } ?? [],
            pollInterval: .seconds(60)
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func R43__a_plugin_offering_two_items_gets_a_step_with_two_cards_after_the_permissions() {
        withDefaults { defaults in
            let tools = [FakeTool("claude-code", title: "Claude Code"), FakeTool("codex", title: "Codex")]
            let model = model(tools, defaults: defaults)
            #expect(model.steps == [.welcome, .permissions, .setup(Self.pluginID), .usage, .done], "the step dots count it")
            model.advance()
            model.advance()
            #expect(model.step == .setup(Self.pluginID))
            let step = model.setup(for: Self.pluginID)
            #expect(step?.setup.title == "코딩 에이전트 연결")
            #expect(step?.setup.items.map(\.title) == ["Claude Code", "Codex"])
            #expect(step?.setup.items.map { OnboardingCard(setup: $0.state) } == [OnboardingCard(.action("연결")), OnboardingCard(.action("연결"))])
            #expect(tools.map(\.performed) == [0, 0], "showing the step connects nothing")
        }
    }

    @Test func R43__pressing_connect_performs_once_and_the_card_turns_connected_with_the_check() {
        withDefaults { defaults in
            let tools = [FakeTool("claude-code", title: "Claude Code"), FakeTool("codex", title: "Codex")]
            let model = model(tools, defaults: defaults)
            let items = model.setup(for: Self.pluginID)!.setup.items
            model.performSetup(items[0])
            #expect(tools.map(\.performed) == [1, 0])
            #expect(OnboardingCard(setup: items[0].state) == OnboardingCard(.done("연결됨")))
            model.performSetup(items[0])
            #expect(tools[0].performed == 1, "a connected card has no button to press")
        }
    }

    @Test func R43__an_unavailable_item_shows_its_reason_and_no_button() {
        withDefaults { defaults in
            let tools = [FakeTool("codex", title: "Codex", state: .unavailable(reason: "설치되지 않았어요"))]
            let model = model(tools, defaults: defaults)
            let item = model.setup(for: Self.pluginID)!.setup.items[0]
            #expect(OnboardingCard(setup: item.state) == OnboardingCard(.note("설치되지 않았어요")))
            model.performSetup(item)
            #expect(tools[0].performed == 0)
        }
    }

    /// Working shows progress and no button; a failure shows the message and offers the button again.
    @Test func R43__working_and_failed_cards() {
        #expect(OnboardingCard(setup: .working) == OnboardingCard(.progress("연결 중")))
        #expect(OnboardingCard(setup: .failed(message: "settings.json을 읽지 못했어요")) == OnboardingCard(.action("다시 시도"), failure: "settings.json을 읽지 못했어요"))
        #expect(OnboardingCard(setup: .failed(message: "실패")).status.offersAction)
        #expect(!OnboardingCard(setup: .working).status.offersAction)
    }

    @Test func R43__enter_and_esc_go_past_the_step_without_connecting_anything() {
        withDefaults { defaults in
            let tools = [FakeTool("claude-code", title: "Claude Code"), FakeTool("codex", title: "Codex")]
            let model = model(tools, defaults: defaults)
            var visited = [model.step]
            while !model.isFinished, visited.count < 10 {
                model.advance()
                if !model.isFinished { visited.append(model.step) }
            }
            #expect(visited == [.welcome, .permissions, .setup(Self.pluginID), .usage, .done])
            #expect(tools.map(\.performed) == [0, 0])
            #expect(OnboardingRecord(defaults: defaults).isCompleted)
        }
    }

    /// The permission cards and the setup cards are one card: the same statuses mean the same look.
    @Test func R14__permission_cards_use_the_same_card_statuses() {
        typealias State = OnboardingModel.PermissionState
        #expect(State.off.card(action: "권한 열기") == OnboardingCard(.action("권한 열기")))
        #expect(State.on.card(action: "켜기") == OnboardingCard(.done("켜짐")))
        #expect(State.needsApproval.card(action: "켜기") == OnboardingCard(.attention("허용 필요", action: "설정 열기")))
        #expect(State.failed("오류").card(action: "켜기") == OnboardingCard(.action("다시 시도"), failure: "오류"))
    }

    @Test func R43__only_enabled_plugins_with_items_offer_a_step() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let id = fixture.newIdentifier()
        let bundle = try fixture.makeBundle(in: fixture.locations.builtIn!, name: "Setup", identifier: id)
        let catalog = fixture.catalog(open: { info in
            (PluginManifest(id: info.identifier, name: "Setup", version: "1.0.0", symbol: "terminal.fill", sdkVersion: NotchKitSDK.version), SetupPlugin.self)
        })
        SetupPlugin.tools = [FakeTool("claude-code", title: "Claude Code"), FakeTool("codex", title: "Codex")]
        catalog.loadAll()
        #expect(catalog.setupSteps().map(\.pluginID) == [id])
        #expect(catalog.setupSteps().first?.setup.items.count == 2)
        catalog.setEnabled(false, for: bundle.path)
        #expect(catalog.setupSteps().isEmpty, "a disabled plugin has no step")
        catalog.setEnabled(true, for: bundle.path)
        SetupPlugin.tools = []
        #expect(catalog.setupSteps().isEmpty, "no items, no step")
    }

    // MARK: Renders

    /// The setup step next to the permission step (same card), then its unavailable and connected
    /// cards. Written only when NOTCH_ONBOARDING_CAPTURE_DIR is set.
    @Test func R43__renders_of_the_setup_step_next_to_the_permission_step() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_ONBOARDING_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try withDefaults { defaults in
            let permissions = model([], defaults: defaults)
            permissions.advance()
            @MainActor func setupStep(_ tools: [FakeTool]) -> OnboardingModel {
                let model = model(tools, defaults: defaults)
                model.advance()
                model.advance()
                return model
            }
            let fresh = setupStep([FakeTool("claude-code", title: "Claude Code"), FakeTool("codex", title: "Codex")])
            try render(HStack(spacing: 24) { OnboardingView(model: permissions); OnboardingView(model: fresh) },
                       to: folder.appendingPathComponent("R43-render-onboarding-agents-T138.png"))
            let unavailable = setupStep([
                FakeTool("claude-code", title: "Claude Code", state: .unavailable(reason: "설치되지 않았어요")),
                FakeTool("codex", title: "Codex", state: .unavailable(reason: "설치되지 않았어요")),
            ])
            try render(OnboardingView(model: unavailable), to: folder.appendingPathComponent("R43-render-onboarding-agents-unavailable-T138.png"))
            let tools = [FakeTool("claude-code", title: "Claude Code"), FakeTool("codex", title: "Codex", state: .failed(message: "app-server에 연결하지 못했어요."))]
            let connected = setupStep(tools)
            connected.performSetup(connected.setup(for: Self.pluginID)!.setup.items[0])
            try render(OnboardingView(model: connected), to: folder.appendingPathComponent("R43-render-onboarding-agents-connected-T138.png"))
        }
    }

    private func render(_ view: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.padding(24).background(Color(white: 0.16)).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.1)
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
