import Foundation
import QuartzCore

/// Opt-in interaction timing. Launch with `PF_PERF_LOG=/path/to/file.log`
/// (or `PF_PERF_LOG=1` for stderr) to record drag phases and main-thread
/// frame gaps. Disabled by default and free when off.
enum PerfLog {
    static let isEnabled = ProcessInfo.processInfo.environment["PF_PERF_LOG"] != nil
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["PF_PERF_LOG"], path != "1" else {
            return nil
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static let start = CACurrentMediaTime()

    /// True between pointer-down and the end of a direct transform, so
    /// frame-gap reporting is limited to interaction.
    static var isInteracting = false

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "%9.1f ms  ", (CACurrentMediaTime() - start) * 1000) + message() + "\n"
        if let handle {
            handle.write(Data(line.utf8))
        } else {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// Runs `body` and logs it when it takes at least `threshold` ms.
    @discardableResult
    static func measure<T>(_ label: @autoclosure () -> String, threshold: Double = 0,
                           _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let t0 = CACurrentMediaTime()
        let result = body()
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms >= threshold { log("\(label()) \(String(format: "%.2f", ms)) ms") }
        return result
    }
}
