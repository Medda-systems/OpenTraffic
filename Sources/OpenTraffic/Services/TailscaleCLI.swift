import Foundation
import OpenTrafficCore

/// Runs short-lived `tailscale` CLI commands off the main thread with a timeout.
struct TailscaleCLI: Sendable {
    let executable: URL

    func status() async -> TailscaleStatus? {
        (try? await run(["status", "--json"])).flatMap(TailscaleStatus.parse)
    }

    func serveConfig() async -> TailscaleServeConfig? {
        (try? await run(["serve", "status", "--json"])).flatMap(TailscaleServeConfig.parse)
    }

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 20) async throws -> Data {
        try await CommandLineTool(executable: executable, name: "Tailscale").run(arguments, timeout: timeout)
    }
}

/// Runs a short-lived command off the main thread with a timeout. Errors carry the tool's first
/// line of stderr.
struct CommandLineTool: Sendable {
    let executable: URL
    /// For messages: "Tailscale didn't respond in time."
    let name: String

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 20) async throws -> Data {
        let executable = executable
        let name = name
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Read both pipes at once so neither can fill up and stall the process.
                let errorOutput = PipeOutput()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorOutput.data = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                let errorData = errorOutput.data
                process.waitUntilExit()
                deadline.cancel()
                let errorText = String(decoding: errorData, as: UTF8.self)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: OpenTrafficError.process("\(name) didn't respond in time."))
                } else if process.terminationStatus != 0 {
                    let message = errorText
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty }
                        .map { $0.replacingOccurrences(of: "error: ", with: "").replacingOccurrences(of: "Error: ", with: "") }
                    continuation.resume(throwing: OpenTrafficError.process(message ?? "\(name) exited with status \(process.terminationStatus)."))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

/// Bytes read on another queue; the dispatch group's wait orders the write before the read.
private final class PipeOutput: @unchecked Sendable {
    var data = Data()
}
