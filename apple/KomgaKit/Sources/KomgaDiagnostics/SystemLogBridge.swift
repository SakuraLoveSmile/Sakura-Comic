import Foundation
import os

/// The one place the Apple side talks to the system log.
///
/// Kept separate from `CoreLog` because the two sinks answer different
/// questions: the ring is what the app can read back (a diagnostics screen, a
/// support export, a test), and `os.Logger` is what Console.app and a crashed
/// device's log show read. Forwarding is a policy switch rather than a code
/// path, so a unit test can hold the ring without drowning the test runner.
enum SystemLogBridge {
    private static let logger = Logger(subsystem: "com.example.comic.komgakit", category: "core")

    static func write(level: CoreLog.Level, target: String, message: String) {
        let line = "\(target): \(message)"
        switch level {
        case .error:
            logger.error("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .debug:
            logger.debug("\(line, privacy: .public)")
        case .trace:
            logger.trace("\(line, privacy: .public)")
        }
    }
}
