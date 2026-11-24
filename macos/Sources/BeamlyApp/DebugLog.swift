import Foundation

/// Optional diagnostics log, enabled with the `--debug` launch argument:
/// `open -a Beamly --args --debug`. Writes to `~/Library/Logs/Beamly.log`.
enum DebugLog {
    static let isEnabled = CommandLine.arguments.contains("--debug")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Beamly.log")
    private static let queue = DispatchQueue(label: "app.beamly.debuglog")

    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
