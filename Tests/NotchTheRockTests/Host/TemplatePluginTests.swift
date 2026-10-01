import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

/// The template plugin, scaffolded by `scripts/new-plugin.sh` and packaged by
/// `scripts/build-plugin.sh` once per test process. The scaffold is made again every run, so the test
/// covers the current template and script; only the package's SwiftPM build folder in the
/// repository's `.build/` is kept, so the build stays incremental.
enum SampleFixture {
    static let bundle: Result<URL, FixtureFailure> = build()

    private static func build() -> Result<URL, FixtureFailure> {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent(".build/test-fixtures")
        let package = fixtures.appendingPathComponent("Sample")
        // Outside the repository, so new-plugin.sh writes an absolute SDK path that still holds after
        // the scaffold moves into `package`.
        let scaffold = manager.temporaryDirectory.appendingPathComponent("NotchTheRockTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: scaffold) }
        do {
            let made = try run(root.appendingPathComponent("scripts/new-plugin.sh"), ["Sample", "--dir", scaffold.path])
            let generated = URL(fileURLWithPath: made.trimmingCharacters(in: .whitespacesAndNewlines))
            try manager.createDirectory(at: package, withIntermediateDirectories: true)
            for name in try manager.contentsOfDirectory(atPath: package.path) where name != ".build" {
                try manager.removeItem(at: package.appendingPathComponent(name))
            }
            for name in try manager.contentsOfDirectory(atPath: generated.path) {
                try manager.moveItem(at: generated.appendingPathComponent(name), to: package.appendingPathComponent(name))
            }
            let out = fixtures.appendingPathComponent("out")
            let built = try run(root.appendingPathComponent("scripts/build-plugin.sh"), [package.path, "--out", out.path])
            return .success(URL(fileURLWithPath: built.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch let failure as FixtureFailure {
            return .failure(failure)
        } catch {
            return .failure(FixtureFailure(description: "\(error)"))
        }
    }

    /// Runs a script and returns its standard output; its standard error goes into the failure.
    private static func run(_ script: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTheRockTests-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errors) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let log = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw FixtureFailure(description: "\(script.lastPathComponent) exited \(process.terminationStatus):\n\(log.suffix(3000))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
@Suite struct TemplatePluginTests {
    /// R03's acceptance through the real loader: a plugin made from the template, put in the user
    /// folder, is listed as needing consent after a reload; once allowed its tab appears, and turning
    /// it off removes the tab and what it showed.
    @Test func R03__template_plugin_needs_consent_then_shows_its_tab_and_hides_it_when_turned_off() async throws {
        let built = try await Task.detached { try SampleFixture.bundle.get() }.value
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let host = NotchHostModel()
        let catalog = fixture.catalog(host: host)
        catalog.loadAll()
        #expect(catalog.records.isEmpty)

        let installed = fixture.locations.user.appendingPathComponent("Sample.notchplugin")
        try FileManager.default.copyItem(at: built, to: installed)
        catalog.reload()
        #expect(catalog.records.map(\.state) == [.needsConsent(PluginCatalog.unknownReason)])
        #expect(catalog.records.first?.name == "Sample")
        #expect(host.tabs.isEmpty)

        try catalog.consent(to: installed.path)
        catalog.reload()
        #expect(catalog.records.map(\.state) == [.on])
        // The app's copy is what loaded; the record still names the bundle in the user folder.
        #expect(FileManager.default.fileExists(atPath: fixture.locations.cache.appendingPathComponent("com.example.sample/Sample.notchplugin/Contents/MacOS/Sample").path))
        #expect(catalog.records.first?.bundleURL.path == installed.path)
        #expect(host.tabs.map(\.pluginID) == ["com.example.sample"])
        #expect(host.tabs.first?.tab.title == "Sample")
        #expect(host.liveActivity?.pluginID == "com.example.sample")

        catalog.setEnabled(false, for: installed.path)
        #expect(catalog.records.map(\.state) == [.off])
        #expect(host.tabs.isEmpty)
        #expect(host.liveActivity == nil)
    }

    /// R15 for a generated plugin: its screen, loaded through the real loader, spreads its symbol and
    /// text to the two edges of what it is offered, at its own width and 80 pt wider, so under a
    /// band wider than the screen the host's margins stay equal.
    @Test func R15__template_screen_spreads_across_a_wider_offer() async throws {
        let built = try await Task.detached { try SampleFixture.bundle.get() }.value
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let host = NotchHostModel()
        let catalog = fixture.catalog(host: host)
        catalog.loadAll()
        let installed = fixture.locations.user.appendingPathComponent("Sample.notchplugin")
        try FileManager.default.copyItem(at: built, to: installed)
        catalog.reload()
        try catalog.consent(to: installed.path)
        catalog.reload()
        let content = try #require(host.tabs.first?.tab.content)
        let ideal = NSHostingView(rootView: content).fittingSize
        for width in [ideal.width, ideal.width + 80] {
            let insets = try await inkInsets(content.frame(width: width))
            print("R15 template screen at \(width) pt (ideal \(ideal)): ink insets left \(insets.left) right \(insets.right) pt")
            #expect(insets.left <= 2 && insets.right <= 2, "the template screen does not reach both edges of \(width) pt: \(insets)")
        }
        catalog.setEnabled(false, for: installed.path)
    }

    /// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
    /// capture counts it) stays from its left and right edges, drawn offscreen at its fitting size.
    /// It sleeps instead of running the main run loop and scans the pixels off the main actor, so
    /// other suites' main-actor tests keep their deadlines meanwhile.
    private func inkInsets(_ view: some View) async throws -> (left: CGFloat, right: CGFloat) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let ink = try #require(await Task.detached { Self.inkColumns(image) }.value, "no ink in \(hosting.bounds.size)")
        let scale = CGFloat(image.width) / hosting.bounds.width
        return (CGFloat(ink.lowerBound) / scale, CGFloat(image.width - 1 - ink.upperBound) / scale)
    }

    /// The leftmost and rightmost pixel columns holding ink; nil without any.
    nonisolated private static func inkColumns(_ image: CGImage) -> ClosedRange<Int>? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, maxX = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        return maxX >= 0 ? minX...maxX : nil
    }
}
