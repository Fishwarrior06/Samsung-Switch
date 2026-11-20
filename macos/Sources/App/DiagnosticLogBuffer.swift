import Foundation

@MainActor
final class DiagnosticLogBuffer {
    private let capacity: Int
    private var entries: [String] = []
    private let dateFormatter: DateFormatter

    init(capacity: Int = 40) {
        self.capacity = capacity
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.dateFormatter = formatter
    }

    func append(_ message: String) {
        let stamp = dateFormatter.string(from: Date())
        entries.append("\(stamp) — \(message)")
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func formattedReport(
        bleStatus: String,
        ownership: String,
        outputDevice: String,
        accessibilityAuthorized: Bool
    ) -> String {
        var lines = [
            "Samsung Switch Diagnostic Summary",
            "BLE: \(bleStatus)",
            "State: \(ownership)",
            "Output: \(outputDevice)",
            "Mac Auto-Pause (Accessibility): \(accessibilityAuthorized ? "Authorized" : "Not authorized")",
            "",
            "Recent Events (\(entries.count)):"
        ]
        if entries.isEmpty {
            lines.append("  (none)")
        } else {
            lines.append(contentsOf: entries.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
