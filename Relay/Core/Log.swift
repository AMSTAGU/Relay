import Foundation
import OSLog

enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.Amaury.Relay"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let speaker = Logger(subsystem: subsystem, category: "speaker")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
    static let switching = Logger(subsystem: subsystem, category: "switch")

    /// Last hour of this process's logs, formatted for pasting into a bug report.
    static func export(summary: String) -> String {
        var lines = [summary, ""]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == subsystem }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
            for entry in entries {
                lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
            }
            if entries.isEmpty { lines.append("(aucun log pour cette session)") }
        } catch {
            lines.append("Logs indisponibles : \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
