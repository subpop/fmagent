import Foundation
import Logging

/// A `TextOutputStream` that appends log lines to a file.
///
/// Used to implement `--log-file`: Xcode swallows the agent subprocess's
/// stderr, so file logging is the only way to get diagnostics out of
/// Xcode-launched runs. Synchronous and lock-guarded; safe to share across
/// the stderr and file handlers behind a `MultiplexLogHandler`.
final class FileLogOutputStream: TextOutputStream, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        do {
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
    }

    func write(_ string: String) {
        lock.withLock {
            if let data = string.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}

enum AgentLogging {
    /// Bootstraps swift-log to stderr, plus `logFileURL` when provided.
    ///
    /// Failures opening the log file fall back to stderr-only with a warning
    /// on stderr, so a bad `--log-file` path can never prevent startup.
    static func bootstrap(debug: Bool, logFileURL: URL?) {
        let level: Logger.Level = debug ? .debug : .info
        if let logFileURL {
            do {
                let fileStream = try FileLogOutputStream(url: logFileURL)
                LoggingSystem.bootstrap { label in
                    var stderrHandler = StreamLogHandler.standardError(label: label)
                    stderrHandler.logLevel = level
                    var fileHandler = StreamLogHandler(
                        label: label, stream: fileStream)
                    fileHandler.logLevel = level
                    return MultiplexLogHandler([stderrHandler, fileHandler])
                }
                return
            } catch {
                fputs(
                    "fmagent: could not open log file \(logFileURL.path): \(error)\n",
                    stderr)
            }
        }
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }
}
