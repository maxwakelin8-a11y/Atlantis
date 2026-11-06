import os

/// App-wide loggers. Mark anything personal with `privacy: .private` (PRD §17).
enum Log {
    static let app = Logger(subsystem: "au.lifeos.atlantis", category: "app")
    static let seqta = Logger(subsystem: "au.lifeos.atlantis", category: "seqta")
    static let web = Logger(subsystem: "au.lifeos.atlantis", category: "web")
    /// Intervals shown in Instruments' "Points of Interest" track (launch, page switches).
    static let signposter = OSSignposter(subsystem: "au.lifeos.atlantis", category: .pointsOfInterest)
}
