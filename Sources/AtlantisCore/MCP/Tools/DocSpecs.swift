import CryptoKit
import Foundation

/// A path to a doc inside the Writer folder, as agents give it: `Project/Sub/Doc.md`, relative to
/// the Writer folder. Never absolute, never `..`. `WriterFiles.resolve` then does the real check
/// (symlinks included).
struct DocPath: Equatable, Sendable {
    /// Components joined with "/", e.g. `Essays/Draft/Intro.md`.
    let relative: String
    var project: String { String(relative.split(separator: "/").first ?? "") }
    var fileName: String { String(relative.split(separator: "/").last ?? "") }
    var stem: String { (fileName as NSString).deletingPathExtension }

    static let docExtensions: Set<String> = ["md", "markdown", "txt"]
    /// Top-level project folders that aren't for documents.
    static let reservedFolders: Set<String> = ["Exports", "assets", "Trash"]

    /// - Parameter addExtension: a name with no extension gets `.md` (used when creating).
    init(_ raw: String, addExtension: Bool = false) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300 else { throw ToolFailure("Argument \"path\" must be a path like \"Project/Doc.md\" (max 300 characters).") }
        guard !text.hasPrefix("/"), !text.hasPrefix("~"), !text.contains("\\"), !text.contains("\0") else {
            throw ToolFailure("Argument \"path\" must be relative to the Writer folder, like \"Project/Doc.md\".")
        }
        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 8 else {
            throw ToolFailure("Argument \"path\" needs a project folder and a file, like \"Project/Doc.md\".")
        }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..", !part.hasPrefix("."), part.count <= 120,
                  !part.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw ToolFailure("Argument \"path\" has a part that isn't allowed (empty, hidden, \"..\" or too long).")
            }
        }
        if addExtension, (parts[parts.count - 1] as NSString).pathExtension.isEmpty { parts[parts.count - 1] += ".md" }
        text = parts.joined(separator: "/")
        guard Self.docExtensions.contains((parts.last! as NSString).pathExtension.lowercased()) else {
            throw ToolFailure("Docs are .md, .markdown or .txt files.")
        }
        guard !Self.reservedFolders.contains(parts[0]) else { throw ToolFailure("\"\(parts[0])\" isn't a project folder.") }
        relative = text
    }

    func absolute(in writer: WriterFiles) throws -> URL {
        do { return try writer.resolve(writer.root.appendingPathComponent(relative).path) }
        catch { throw ToolFailure("That path is outside the Writer folder.") }
    }

    /// The project's folder, which must already exist (agents don't create projects).
    func projectURL(in writer: WriterFiles) throws -> URL {
        let url = try writer.resolve(writer.root.appendingPathComponent(project).path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolFailure("There's no project folder \"\(project)\". Use atlantis_docs_list to see the projects.")
        }
        return url
    }
}

/// What `atlantis_doc_write` and an Inbox `doc.edit` item hold.
struct DocWrite: Sendable, Equatable {
    enum Mode: String, Sendable { case create, replace }

    var path: DocPath
    var text: String
    var mode: Mode
    /// For `replace`: a short hash of the text the proposal was made against, so Accept refuses if
    /// the doc has changed since.
    var base: String?

    static let maxText = 50_000

    init(arguments args: JSONValue, writer: WriterFiles) throws {
        path = try DocPath(try args.requireString("path", maxLength: 300), addExtension: true)
        text = try Self.readText(args)
        let state = try Self.currentState(path, writer: writer)
        mode = state.0
        base = state.1
    }

    /// From an Inbox line: `path`, `text` (encoded), `mode` and `base`.
    init(item: InboxItem) throws {
        guard let rawPath = item.field("path") else { throw ToolFailure("This proposal has no path.") }
        path = try DocPath(rawPath)
        guard let encoded = item.field("text") else { throw ToolFailure("This proposal has no text.") }
        text = InboxText.decode(encoded)
        guard text.count <= Self.maxText else { throw ToolFailure("The proposed text is too long.") }
        mode = item.field("mode").flatMap(Mode.init(rawValue:)) ?? .replace
        base = item.field("base")
    }

    private static func readText(_ args: JSONValue) throws -> String {
        guard let text = args["text"]?.stringValue else { throw ToolFailure("Missing required argument \"text\" (the doc's full Markdown).") }
        guard text.count <= maxText else { throw ToolFailure("Argument \"text\" is too long (max \(maxText) characters).") }
        guard !text.contains("\0") else { throw ToolFailure("Argument \"text\" can't contain NUL characters.") }
        return text
    }

    /// Create if the doc isn't there; otherwise replace, against the text as it is now.
    private static func currentState(_ path: DocPath, writer: WriterFiles) throws -> (Mode, String?) {
        let url = try path.absolute(in: writer)
        guard FileManager.default.fileExists(atPath: url.path) else { return (.create, nil) }
        guard let existing = try? writer.read(url.path) else { throw ToolFailure("That doc exists but can't be read as text.") }
        return (.replace, hash(existing))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    var inboxFields: [InboxItem.Field] {
        var fields: [InboxItem.Field] = [.init(key: "path", value: path.relative), .init(key: "mode", value: mode.rawValue)]
        if let base { fields.append(.init(key: "base", value: base)) }
        fields.append(.init(key: "text", value: InboxText.encode(text)))
        return fields
    }

    var summary: String {
        Clip.text("\(mode == .create ? "Create doc" : "Edit doc"): \(path.relative)", 200)
    }

    /// Writes the doc. Creating never overwrites; replacing refuses if the doc changed since the proposal.
    func apply(in writer: WriterFiles) throws {
        _ = try path.projectURL(in: writer)
        let url = try path.absolute(in: writer)
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch mode {
        case .create:
            guard !exists else { throw ToolFailure("\(path.relative) already exists now. It wasn't overwritten.") }
        case .replace:
            guard exists else { throw ToolFailure("\(path.relative) isn't there any more.") }
            if let base {
                let current = try writer.read(url.path)
                guard Self.hash(current) == base else {
                    throw ToolFailure("\(path.relative) changed after this was proposed. Ask the agent to propose it again.")
                }
            }
        }
        try writer.write(url.path, text: text)
    }
}
