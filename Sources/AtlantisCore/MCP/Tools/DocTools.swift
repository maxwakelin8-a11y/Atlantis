import Foundation

/// `atlantis_docs_list`, `atlantis_docs_search`, `atlantis_doc_read`, `atlantis_doc_write`,
/// `atlantis_doc_export` (PRD §8). They only see the Writer folder: every path is relative to it,
/// checked, then resolved by `WriterFiles`, which refuses anything outside (symlinks included).
enum DocTools {
    static func register(in registry: ToolRegistry, context: MCPToolContext) {
        registerList(registry, context)
        registerSearch(registry, context)
        registerRead(registry, context)
        registerWrite(registry, context)
        registerExport(registry, context)
    }

    private static func fail(_ error: Error) -> ToolFailure {
        if let failure = error as? ToolFailure { return failure }
        if let writer = error as? WriterFiles.Failure { return ToolFailure(writer.errorDescription ?? "That file can't be used.") }
        return ToolFailure("That file couldn't be read or written.")
    }

    // MARK: List

    private static func registerList(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_docs_list",
            description: "List the user's docs. With no project: the Writer projects (folders) and how many docs each holds. With a project: its docs (paths to use with atlantis_doc_read), newest first.",
            inputSchema: schema(["project": prop("A project folder name from the first listing.")]),
            kind: .read
        )) { args in
            let writer = context.writer
            if let project = try args.optionalString("project", maxLength: 120) {
                guard !project.contains("/") else { throw ToolFailure("\"project\" is a folder name, not a path.") }
                let folder = try DocPath("\(project)/x.md").project
                let docs = try await Self.docs(in: folder, writer: writer)
                return .json(.make(["project": .string(folder), "count": .int(docs.count), "truncated": .bool(docs.count > 300),
                                    "docs": .array(docs.prefix(300).map { doc in
                                        .make(["path": .string(doc.path), "title": .string(doc.title), "bytes": .int(doc.size), "modified": .string(doc.modified)])
                                    })]))
            }
            let entries = (try? writer.list(writer.root.path)) ?? []
            var projects: [JSONValue] = []
            for entry in entries where entry.kind == .dir && !entry.name.hasPrefix(".") {
                let count = (try? await Self.docs(in: entry.name, writer: writer).count) ?? 0
                projects.append(.make(["project": .string(entry.name), "docs": .int(count)]))
            }
            return .json(.make(["count": .int(projects.count), "projects": .array(projects)]))
        }
    }

    struct DocInfo { var path: String; var title: String; var size: Int; var modified: String; var mtime: Double }

    /// Every doc in a project (not Exports/assets/Trash, no hidden or symlinked items), newest first.
    static func docs(in project: String, writer: WriterFiles) async throws -> [DocInfo] {
        let root = try writer.resolve(writer.root.appendingPathComponent(project).path)
        var found: [DocInfo] = []
        func visit(_ dir: URL, rel: String, depth: Int) {
            guard depth < 8, found.count < 5_000, let entries = try? writer.list(dir.path) else { return }
            for entry in entries where !entry.name.hasPrefix(".") {
                let childRel = rel.isEmpty ? entry.name : "\(rel)/\(entry.name)"
                if entry.kind == .dir {
                    if depth == 0, DocPath.reservedFolders.contains(entry.name) { continue }
                    visit(dir.appendingPathComponent(entry.name), rel: childRel, depth: depth + 1)
                } else if DocPath.docExtensions.contains((entry.name as NSString).pathExtension.lowercased()) {
                    let url = dir.appendingPathComponent(entry.name)
                    guard let stat = try? writer.stat(url.path) else { continue }
                    let date = Date(timeIntervalSince1970: stat.mtime / 1000)
                    found.append(DocInfo(path: "\(project)/\(childRel)", title: (entry.name as NSString).deletingPathExtension,
                                         size: stat.size, modified: ISO8601DateFormatter().string(from: date), mtime: stat.mtime))
                }
            }
        }
        visit(root, rel: "", depth: 0)
        return found.sorted { $0.mtime > $1.mtime }
    }

    // MARK: Search

    private static func registerSearch(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_docs_search",
            description: "Search every doc's title and text (case and accent insensitive). Returns matching docs with short snippets around the matches. Use atlantis_doc_read for the whole doc.",
            inputSchema: schema([
                "query": prop("Text to find (max 200 characters)."),
                "project": prop("Only search this project."),
                "limit": prop("Most docs to return (1-50, default 20).", "integer"),
            ], required: ["query"]),
            kind: .read
        )) { args in
            let query = try args.requireString("query", maxLength: 200)
            let project = try args.optionalString("project", maxLength: 120)
            let limit = try args.optionalInt("limit", in: 1...50) ?? 20
            let result = context.writer.search(query, limit: project == nil ? limit : 200, maxSnippets: 3)
            var hits = result.hits
            if let project { hits = hits.filter { $0.project == project } }
            return .json(.make([
                "count": .int(min(hits.count, limit)), "truncated": .bool(result.truncated || hits.count > limit),
                "docs": .array(hits.prefix(limit).map { hit in
                    .make(["path": .string("\(hit.project)/\(hit.relPath)"), "title": .string(hit.title),
                           "title_match": hit.titleMatches ? .bool(true) : nil, "matches": .int(hit.count),
                           "snippets": .array(hit.snippets.map { .string(Clip.text($0.before + $0.match + $0.after, 200)) })])
                }),
            ]))
        }
    }

    // MARK: Read

    private static let readLimit = 50_000

    private static func registerRead(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_doc_read",
            description: "Read a doc's Markdown (including its front matter). Long docs come back in parts: pass the returned next_offset as offset to continue.",
            inputSchema: schema([
                "path": prop("The doc, like \"Project/Doc.md\" (from atlantis_docs_list or atlantis_docs_search)."),
                "offset": prop("Character to start from (default 0).", "integer"),
            ], required: ["path"]),
            kind: .read
        )) { args in
            let path = try DocPath(try args.requireString("path", maxLength: 300))
            let offset = try args.optionalInt("offset", in: 0...Int.max) ?? 0
            let writer = context.writer
            let text: String
            do { text = try writer.read(try path.absolute(in: writer).path) } catch { throw fail(error) }
            let chars = Array(text)
            guard offset <= chars.count else { throw ToolFailure("offset is past the end of the doc (\(chars.count) characters).") }
            let end = min(chars.count, offset + readLimit)
            return .json(.make([
                "path": .string(path.relative), "characters": .int(chars.count),
                "offset": .int(offset), "next_offset": end < chars.count ? .int(end) : nil,
                "text": .string(String(chars[offset..<end])),
            ]))
        }
    }

    // MARK: Write

    private static func registerWrite(_ registry: ToolRegistry, _ context: MCPToolContext) {
        let definition = ToolDefinition(
            name: "atlantis_doc_write",
            description: "Create a doc in an existing Writer project, or propose a new version of an existing doc. The path must be inside a project that already exists (atlantis_docs_list shows them). If the doc doesn't exist and the user has allowed it, it's created. In every other case (not allowed, or the doc already exists) the full new text is proposed in the Atlantis Inbox for the user to accept, and nothing is written yet. Never overwrites directly. Don't retry a proposal.",
            inputSchema: schema([
                "path": prop("The doc, like \"Project/Doc.md\". \".md\" is added if missing."),
                "text": prop("The doc's complete Markdown (max 50,000 characters)."),
            ], required: ["path", "text"]),
            kind: .gatedWrite)
        registry.register(definition, proposal: { args in
            let spec = try DocWrite(arguments: args, writer: context.writer)
            _ = try spec.path.projectURL(in: context.writer)
            return InboxProposal(kind: GatedAction.docWrite.inboxKind, title: spec.summary, source: MCPCaller.source, fields: spec.inboxFields)
        }) { args in
            let writer = context.writer
            let spec = try DocWrite(arguments: args, writer: writer)
            _ = try spec.path.projectURL(in: writer)
            if spec.mode == .replace {
                // Even when creating is allowed, an existing doc is only ever changed with approval.
                let receipt = try await context.inbox.post(InboxProposal(
                    kind: GatedAction.docWrite.inboxKind, title: spec.summary, source: MCPCaller.source, fields: spec.inboxFields))
                return ToolResult(text: "Not written yet. \(spec.path.relative) already exists, so the new version was proposed in the Atlantis Inbox (id \(receipt.id)) for the user to accept. Don't retry.")
            }
            do { try spec.apply(in: writer) } catch { throw fail(error) }
            return .json(.make(["created": .bool(true), "path": .string(spec.path.relative)]))
        }
    }

    // MARK: Export

    private static func registerExport(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_doc_export",
            description: "Export a doc to PDF or Word (.docx). The file is saved in the project's Exports folder (never overwriting an earlier export) and its path is returned. PDF needs Chrome, Helium or a similar browser installed.",
            inputSchema: schema([
                "path": prop("The doc, like \"Project/Doc.md\"."),
                "format": prop("pdf or docx."),
            ], required: ["path", "format"]),
            kind: .action
        )) { args in
            let path = try DocPath(try args.requireString("path", maxLength: 300))
            guard let format = try args.optionalChoice("format", ["pdf", "docx"]) else {
                throw ToolFailure("Missing required argument \"format\" (pdf or docx).")
            }
            let writer = context.writer
            let text: String
            do { text = try writer.read(try path.absolute(in: writer).path) } catch { throw fail(error) }
            let projectDir = try path.projectURL(in: writer)
            let exports = projectDir.appendingPathComponent("Exports", isDirectory: true)
            // A free name: "Doc.pdf", then "Doc 2.pdf", …
            var target = exports.appendingPathComponent("\(path.stem).\(format)")
            var n = 2
            while FileManager.default.fileExists(atPath: target.path), n < 1_000 {
                target = exports.appendingPathComponent("\(path.stem) \(n).\(format)")
                n += 1
            }
            let checked: URL
            do { checked = try writer.resolve(target.path) } catch { throw fail(error) }
            let html = MarkdownHTML.document(markdown: text, title: path.stem)
            do { try await context.exportDocument(html, format, checked) } catch {
                throw ToolFailure("Export failed: \(error.localizedDescription)")
            }
            return .json(.make(["exported": .bool(true), "file": .string(checked.path), "format": .string(format)]))
        }
    }
}
