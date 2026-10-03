import Foundation
import NotchKit
import SwiftUI

/// Shows how far the D-STACK runs of the user's projects have come: goal title and state, plans,
/// tasks, requirements and milestones done, the plans in progress and the latest activity. Projects
/// come from Claude Code's project folders and from folders added in settings. It only reads the
/// stores' files and never runs the `dstack` CLI: no file in a D-STACK store or a project folder is
/// written. Its own settings (the folders added and removed) live in the app's plugin storage.
@MainActor
public final class DStackPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.dstack",
        name: "D-STACK",
        version: "1.0.0",
        symbol: "square.stack.3d.up",
        sdkVersion: NotchKitSDK.version
    )

    let model: DStackModel
    private var isActive = false

    public convenience init(context: NotchContext) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            context: context,
            discovery: ProjectDiscovery(
                claudeProjects: home.appendingPathComponent(".claude/projects"),
                fileSystemRoot: URL(fileURLWithPath: "/")
            ),
            now: Date.init
        )
    }

    init(context: NotchContext, discovery: ProjectDiscovery, now: @escaping () -> Date, interval: Duration = .seconds(5)) {
        model = DStackModel(discovery: discovery, folders: ProjectFolders(defaults: context.storage.defaults), now: now, interval: interval)
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        model.activate()
    }

    public func deactivate() {
        guard isActive else { return }
        model.deactivate()
        isActive = false
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [model] in
            DStackScreen(model: model)
        }
    }

    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.wide, .small]) { [model] size in
            DStackTile(model: model, size: size)
        }
    }

    /// The folder list does not fit a declared item, so it stays the plugin's own.
    public var settingsView: AnyView? {
        AnyView(DStackSettingsView(model: model))
    }

    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "D-STACK을 쓰는 프로젝트의 목표와 계획, 태스크, 요구사항이 얼마나 진행됐는지 노치에 보여줘요. 파일을 읽기만 하고 아무것도 쓰지 않아요.",
            permissions: [
                PluginPermission(.files(path: "~/.claude/projects"), reason: "Claude Code에서 연 프로젝트 가운데 D-STACK을 쓰는 곳을 찾으려고 폴더 이름을 읽어요."),
                PluginPermission(.files(path: "프로젝트 폴더/.dstack"), reason: "진행 상황을 보여 주려고 각 프로젝트의 D-STACK 저장소 파일을 읽어요."),
            ]
        )
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(DStackPlugin.self)
}
