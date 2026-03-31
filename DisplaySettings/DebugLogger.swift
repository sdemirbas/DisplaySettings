// DebugLogger.swift
// In-memory log for DDC diagnostics, viewable in Settings.

import Foundation

@MainActor
final class DebugLogger {
    static let shared = DebugLogger()

    private(set) var entries: [String] = []
    private let capacity = 200

    private init() {}

    func log(_ message: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        entries.append("[\(timestamp)] \(message)")
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var text: String { entries.joined(separator: "\n") }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
