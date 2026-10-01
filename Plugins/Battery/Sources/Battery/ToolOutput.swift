import Foundation

/// A system tool that could not run or exited with an error.
struct ToolError: Error, CustomStringConvertible {
    let executable: String
    let status: Int32

    var description: String { "\(executable) exited with status \(status)" }
}

/// Runs `executable` on a background queue and returns what it printed. The caller's thread never
/// waits on the process.
func toolOutput(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Read before waiting: a full pipe would otherwise keep the tool from exiting.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: ToolError(executable: executable, status: process.terminationStatus))
            }
        }
    }
}
