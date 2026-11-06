import os

/// App-wide loggers. Mark anything personal with `privacy: .private` (PRD §17).
enum Log {
    static let app = Logger(subsystem: "au.lifeos.atlantis", category: "app")
}
