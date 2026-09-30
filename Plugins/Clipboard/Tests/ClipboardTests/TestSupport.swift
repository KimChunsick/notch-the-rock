import AppKit
import CryptoKit
import Foundation
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
