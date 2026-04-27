import Foundation

public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    public static func findExecutable(named name: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 15,
        currentDirectoryURL: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw EnvViewerError.processFailed("Failed to run \(executable.path): \(error.localizedDescription)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw EnvViewerError.timedOut(executable.lastPathComponent)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    public static func runShell(
        _ command: String,
        timeout: TimeInterval = 15,
        currentDirectoryURL: URL? = nil
    ) throws -> ProcessResult {
        try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", command],
            timeout: timeout,
            currentDirectoryURL: currentDirectoryURL
        )
    }
}
