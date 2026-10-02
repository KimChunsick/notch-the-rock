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
        model.activate()
    }

    public func deactivate() {
        model.deactivate()
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

    public var settingsView: AnyView? {
        AnyView(DStackSettingsView(model: model))
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(DStackPlugin.self)
}
