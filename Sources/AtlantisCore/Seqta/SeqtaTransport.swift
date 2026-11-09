import Foundation

/// Why a sync stopped.
public enum SeqtaSyncError: Error, Equatable, Sendable {
    /// The session is gone (login page, 401, or no user in the login reply). The UI tells the
    /// user to sign in through the SEQTA tab.
    case notSignedIn
    /// No SEQTA address is set in Settings.
    case notConfigured
    /// SEQTA couldn't be reached (offline, timeout, blocked).
    case network(String)
    /// SEQTA answered with something we couldn't read.
    case badResponse(String)
    /// A request outside the read-only allow-list. A bug, never user-triggered.
    case blockedRequest(String)
    /// Every part of the sync failed.
    case nothingSynced([String: String])

    public var message: String {
        switch self {
        case .notSignedIn: "Not signed in to SEQTA. Sign in from the SEQTA tab, then refresh."
        case .notConfigured: "No SEQTA address is set. Add it in Settings."
        case .network(let text): "Couldn't reach SEQTA (\(text))."
        case .badResponse(let text): "SEQTA sent something unexpected (\(text))."
        case .blockedRequest(let path): "Refused a request that isn't read-only (\(path))."
        case .nothingSynced(let failures):
            "Nothing synced: " + failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        }
    }
}

/// One POST to SEQTA's JSON API. The body is kept as JSON text so the request is trivially
/// `Sendable` and can be handed to the page as is.
public struct SeqtaRequest: Sendable, Equatable {
    public let path: String
    public let body: String

    public init(path: String, body: [String: Any] = [:]) {
        self.path = path
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        self.body = String(decoding: data, as: UTF8.self)
    }

    /// The only endpoints Atlantis may call. All of them read; nothing here saves, sends,
    /// submits or changes a setting (PRD §7d: bots and sync never send messages). Messages use
    /// one endpoint for everything, so its `action` is checked too.
    public var isAllowed: Bool {
        let clean = path.hasSuffix("?") ? String(path.dropLast()) : path
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? JSONObject
        switch clean {
        case "/seqta/student/load/message":
            return ["list", "message"].contains(object?.string("action") ?? "")
        case "/seqta/student/login":
            return object?.string("mode") == "normal"
        case "/seqta/student/load/timetable", "/seqta/student/load/notices", "/seqta/student/load/subjects",
             "/seqta/student/load/courses", "/seqta/student/load/prefs",
             "/seqta/student/assessment/list/upcoming", "/seqta/student/assessment/list/past",
             "/seqta/student/assessment/get":
            return true
        default:
            return false
        }
    }
}

public struct SeqtaResponse: Sendable, Equatable {
    /// HTTP status, or 0 when the request never got an answer.
    public let status: Int
    public let body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

/// How the sync reaches SEQTA: in the app a hidden web view with the logged-in session, in
/// tests a fake. A transport is opened once per sync and closed when it ends.
public protocol SeqtaTransport: Sendable {
    /// Loads SEQTA's origin so requests are same-origin with the session. Throws
    /// `SeqtaSyncError.notSignedIn` if loading ends up at a sign-in page.
    func open() async throws
    /// Sends the requests (in parallel, a few at a time) and returns the answers in order.
    func send(_ requests: [SeqtaRequest]) async throws -> [SeqtaResponse]
    /// Unloads everything. Always called, also after an error.
    func close() async
}

/// SEQTA wraps every answer as `{"payload": …, "status": "200"}`.
enum SeqtaEnvelope {
    /// The `payload` of an answer, or the reason there isn't one.
    static func payload(_ response: SeqtaResponse) throws -> Any {
        if response.status == 0 { throw SeqtaSyncError.network("no answer") }
        if response.status == 401 || response.status == 403 { throw SeqtaSyncError.notSignedIn }
        guard (200..<300).contains(response.status) else { throw SeqtaSyncError.badResponse("HTTP \(response.status)") }
        guard let root = try? JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [.fragmentsAllowed]) else {
            // A login page comes back as HTML with a 200.
            if response.body.lowercased().contains("<html") { throw SeqtaSyncError.notSignedIn }
            throw SeqtaSyncError.badResponse("not JSON")
        }
        if let object = root as? JSONObject {
            if let status = object.string("status"), status == "401" || status == "403" { throw SeqtaSyncError.notSignedIn }
            if let payload = object["payload"], !(payload is NSNull) { return payload }
            if let status = object.string("status"), status != "200" { throw SeqtaSyncError.badResponse("status \(status)") }
            throw SeqtaSyncError.badResponse("no payload")
        }
        return root
    }
}
