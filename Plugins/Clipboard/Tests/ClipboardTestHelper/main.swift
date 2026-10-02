// Saves a clipboard history the way the plugin does and exits: opens the history in the folder
// given as the first argument, records every later argument as a copied text, waits for the write
// and prints the history key in hex. HistoryKeyTests runs it as another process and then reopens
// the folder itself. It is a target without a product, so scripts/build-plugin.sh never builds or
// packages it, and it never touches a pasteboard.
//
// It needs `@testable import`, which only a debug build allows (`swift test` builds debug). A plain
// `swift build -c release` builds every target, this one included, so a release build gets a stub.
import Foundation

#if DEBUG
@testable import Clipboard

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let opened = try ClipboardStore.open(in: directory)
let history = ClipboardHistory { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
history.open(opened.store)
for text in CommandLine.arguments.dropFirst(2) {
    history.record(.text(text))
}
history.flush()
print(opened.key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() })
#else
FileHandle.standardError.write(Data("ClipboardTestHelper runs only in a debug build\n".utf8))
exit(1)
#endif
