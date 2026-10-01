import AppKit
import CryptoKit
import Foundation
import os
import SwiftUI
import Testing
@testable import Clipboard

/// A private pasteboard for one test. Release it with `releaseGlobally()`; the user's general
/// pasteboard is never touched.
func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: .init("com.notchtherock.clipboard.tests.\(UUID().uuidString)"))
}

func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipboard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
}

func makeKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
}

/// A PNG of a gradient; `seed` changes the blue channel so different seeds give different images.
func samplePNG(width: Int = 120, height: Int = 80, seed: Int = 0) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    for y in 0..<height {
        for x in 0..<width {
            let color = NSColor(
                deviceRed: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                blue: CGFloat(seed % 256) / 255, alpha: 1
            )
            rep.setColor(color, atX: x, y: y)
        }
    }
    return rep.representation(using: .png, properties: [:])!
}

/// Every regular file under `directory`, recursively.
func files(in directory: URL) throws -> [URL] {
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    return try (enumerator?.allObjects as? [URL] ?? []).filter {
        try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }
}

/// The bytes of every regular file under `directory`, keyed by its path relative to `directory`.
func contents(of directory: URL) throws -> [String: Data] {
    let base = directory.resolvingSymlinksInPath().path + "/"
    var result: [String: Data] = [:]
    for file in try files(in: directory) {
        result[String(file.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: file)
    }
    return result
}

/// A disk that refuses image files while `failsImages` is on and the list file while `failsList` is
/// on, as a full disk would; other writes go through. Pass `write(_:to:)` as the store's `writeFile`.
final class WriteFault: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (images: false, list: false))

    var failsImages: Bool {
        get { state.withLock { $0.images } }
        set { state.withLock { $0.images = newValue } }
    }

    var failsList: Bool {
        get { state.withLock { $0.list } }
        set { state.withLock { $0.list = newValue } }
    }

    func write(_ data: Data, to url: URL) throws {
        let isImage = url.pathExtension == ClipboardStore.imageExtension
        if isImage ? failsImages : failsList {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: .atomic)
    }
}

/// A disk whose list writes wait until `open()` is called, so a test sees a list write in
/// progress; image files, written on the main actor, go through. Pass `write(_:to:)` as the store's
/// `writeFile`, and open the gate before any flush.
final class WriteGate: Sendable {
    private let isOpen = OSAllocatedUnfairLock(initialState: false)

    func open() {
        isOpen.withLock { $0 = true }
    }

    func write(_ data: Data, to url: URL) throws {
        if url.pathExtension != ClipboardStore.imageExtension {
            while !isOpen.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        try data.write(to: url, options: .atomic)
    }
}

/// A clock that moves only when a test sets `now`.
@MainActor
final class ManualClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

/// Where the store keeps the image file of the entry `id`.
func imageFile(for id: UUID, in directory: URL) -> URL {
    directory.appendingPathComponent(id.uuidString).appendingPathExtension(ClipboardStore.imageExtension)
}

/// Collects what the history reports as errors.
@MainActor
final class ErrorLog {
    var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}

@MainActor
func makeHistory(directory: URL, key: SymmetricKey, errors: ErrorLog = ErrorLog()) -> ClipboardHistory {
    let history = ClipboardHistory(logError: errors.append)
    history.open(ClipboardStore(directory: directory, key: key))
    return history
}

/// `view` drawn offscreen in a dark window at its ideal size, at the window's backing scale, as
/// the app draws a tab.
@MainActor
func renderOffscreen(_ view: some View) throws -> (image: CGImage, scale: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    window.setContentSize(hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    return (try #require(rep.cgImage), window.backingScaleFactor)
}

/// The tests that time how fast a copy shows and the tests that hold the main actor for long
/// (offscreen windows, hosting views, a deliberate stall) run here one at a time, so none of them
/// holds the main actor while another is timed. Tests outside this suite still run in parallel.
@Suite(.serialized) struct MainActorTimingTests {}

/// Waits until the main actor has answered every short wait on time for 200 ms in a row (giving up
/// after 30 s), so a burst of other tests holding it ends before a copy is timed. Nothing is
/// discounted afterwards: the copy's own time is measured as it is.
@MainActor
func waitForAQuietMainActor() async {
    let giveUp = ContinuousClock.now + .seconds(30)
    var quiet = Duration.zero
    while quiet < .milliseconds(200), ContinuousClock.now < giveUp {
        let start = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(10))
        let took = ContinuousClock.now - start
        quiet = took < .milliseconds(25) ? quiet + took : .zero
    }
}
