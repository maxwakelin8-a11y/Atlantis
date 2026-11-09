import Foundation

/// Things the pages fetch when the user asks, not during the morning sync: one message's body,
/// the people lists for the compose view, and a file's bytes. Each call opens the hidden
/// connection, makes its one request, closes it (idle = zero work), and only reads: every POST
/// passes `SeqtaRequest.isAllowed`, and downloads go through `SeqtaFileRequest`.
public struct SeqtaOnDemand: Sendable {
    public let transport: any SeqtaTransport
    public let cache: SeqtaCache

    public init(transport: any SeqtaTransport, cache: SeqtaCache = SeqtaCache()) {
        self.transport = transport
        self.cache = cache
    }

    /// The whole message (from the cache if it was opened before), saved for next time.
    public func message(id: Int, forceRefresh: Bool = false) async throws -> Message {
        if !forceRefresh, let cached = cache.message(id: id) { return cached }
        let answer = try await one(SeqtaRequest(path: "/seqta/student/load/message", body: ["action": "message", "id": id]))
        guard var message = SeqtaDecoding.message(try SeqtaEnvelope.payload(answer)) else {
            throw SeqtaSyncError.badResponse("message")
        }
        // The list knows things the single message may not (who sent it, their id).
        if let listed = cache.messages()?.items.first(where: { $0.id == id }) {
            message.summary.senderID = message.summary.senderID ?? listed.senderID
            if message.summary.sender.isEmpty { message.summary.sender = listed.sender }
            if message.summary.senderType.isEmpty { message.summary.senderType = listed.senderType }
            message.summary.date = message.summary.date ?? listed.date
        }
        try? cache.saveMessage(message)
        return message
    }

    /// Everyone of one kind the student can message. Big lists: callers keep the result for the
    /// life of the compose window instead of asking again.
    public func people(_ kind: SeqtaPerson.Kind) async throws -> [SeqtaPerson] {
        let answer = try await one(SeqtaRequest(path: "/seqta/student/load/message/people", body: ["mode": kind.rawValue]))
        return SeqtaDecoding.people(try SeqtaEnvelope.payload(answer), kind: kind)
    }

    /// A file's bytes and the name SEQTA gives it.
    public func file(_ request: SeqtaFileRequest) async throws -> SeqtaFileResponse {
        try await transport.open()
        do {
            let response = try await transport.download(request)
            await transport.close()
            if response.status == 401 || response.status == 403 { throw SeqtaSyncError.notSignedIn }
            guard (200..<300).contains(response.status), !response.data.isEmpty else {
                throw SeqtaSyncError.badResponse(response.status == 0 ? "no answer" : "HTTP \(response.status)")
            }
            return response
        } catch {
            await transport.close()
            throw error
        }
    }

    private func one(_ request: SeqtaRequest) async throws -> SeqtaResponse {
        guard request.isAllowed else { throw SeqtaSyncError.blockedRequest(request.path) }
        try await transport.open()
        do {
            let responses = try await transport.send([request])
            await transport.close()
            guard let first = responses.first else { throw SeqtaSyncError.badResponse("missing answer") }
            return first
        } catch {
            await transport.close()
            throw error
        }
    }
}

/// Downloaded SEQTA files, kept under `AppSupport.seqtaFiles/<uuid>/<name>` so the same file is
/// downloaded once. Names come from SEQTA, so they are cleaned before they touch the disk.
public struct SeqtaFileCache: Sendable {
    public let root: URL

    public init(root: URL = AppSupport.seqtaFiles) { self.root = root }

    /// A file name with no folders, no leading dots and no control characters.
    public static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        var clean = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.count > 120 {
            let ext = (clean as NSString).pathExtension
            clean = String(clean.prefix(100)) + (ext.isEmpty || ext.count > 12 ? "" : "." + ext)
        }
        return clean.isEmpty ? "file" : clean
    }

    /// The file name SEQTA's `Content-Disposition` header names, if any.
    public static func name(fromDisposition header: String) -> String? {
        if let range = header.range(of: #"filename\*\s*=\s*[^']*''([^;]+)"#, options: .regularExpression) {
            let value = header[range].components(separatedBy: "''").last ?? ""
            if let decoded = value.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        if let range = header.range(of: #"filename\s*=\s*"?([^";]+)"?"#, options: .regularExpression) {
            let raw = String(header[range]).drop { $0 != "=" }.dropFirst()
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !value.isEmpty { return value }
        }
        return nil
    }

    public func url(uuid: String, name: String) -> URL {
        root.appendingPathComponent(uuid.lowercased(), isDirectory: true).appendingPathComponent(Self.safeName(name))
    }

    /// The downloaded file, if it's already here.
    public func existing(uuid: String, name: String) -> URL? {
        let url = url(uuid: uuid, name: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func store(_ data: Data, uuid: String, name: String) throws -> URL {
        let url = url(uuid: uuid, name: name)
        for dir in [root, url.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
