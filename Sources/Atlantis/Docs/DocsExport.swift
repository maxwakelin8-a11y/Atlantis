import Foundation

/// Turns the Writer's compiled HTML into Word/RTF/OpenDocument (macOS's textutil) or PDF (a
/// headless Chromium, as the BetterSEQTA+ Writer did: WebKit can't print @page margin boxes, which
/// the Writer uses for page numbers), and
/// imported files into HTML or Markdown. Ported from seqta-mcp src/writer.mjs.
enum DocsExport {
    enum Failure: Error, LocalizedError {
        case unknownFormat(String)
        case noBrowser
        case noOutput
        case tooBig
        case notText
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unknownFormat(let f): "Unknown export format: \(f)"
            case .noBrowser: "PDF export needs Helium or Chrome installed. Export as Word instead and save it as PDF."
            case .noOutput: "The file didn't come out. Try again, or export as Word."
            case .tooBig: "That file is too big to import (20 MB max)."
            case .notText: "That file isn't UTF-8 text."
            case .unsupported: "Import works with .md, .txt, .docx, .doc, .rtf, .odt and .html files."
            }
        }
    }

    private static let browsers = [
        "/Applications/Helium.app/Contents/MacOS/Helium",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    ]

    static func export(html: String, format: String, to target: URL) async throws {
        guard ["docx", "rtf", "odt", "pdf"].contains(format) else { throw Failure.unknownFormat(format) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atlantis-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("export.html")
        try Data(html.utf8).write(to: src)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if format == "pdf" {
            guard let browser = browsers.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw Failure.noBrowser
            }
            let profile = tmp.appendingPathComponent("profile")
            _ = try await run(browser, [
                "--headless=new", "--user-data-dir=\(profile.path)", "--disable-gpu", "--no-first-run",
                "--no-default-browser-check", "--no-pdf-header-footer", "--virtual-time-budget=4000",
                // No network (AGENTS.md): the page is a local file; stop Chromium's own background calls.
                "--disable-background-networking", "--disable-component-update", "--disable-sync",
                "--disable-default-apps", "--no-pings", "--disable-domain-reliability",
                "--print-to-pdf=\(target.path)", src.absoluteString,
            ], timeout: 60)
        } else {
            _ = try await run("/usr/bin/textutil", ["-convert", format, "-inputencoding", "UTF-8",
                                                    "-output", target.path, src.path], timeout: 30)
        }
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure.noOutput }
    }

    /// An imported file → `["markdown": …]` for text files, `["html": …]` for the rest.
    static func convert(ext: String, base64: String) async throws -> [String: String] {
        guard let data = Data(base64Encoded: base64) else { throw Failure.unsupported }
        guard data.count <= 20_000_000 else { throw Failure.tooBig }
        if [".md", ".markdown", ".txt"].contains(ext) {
            guard let text = String(validating: data, as: UTF8.self) else { throw Failure.notText }
            return ["markdown": text]
        }
        guard [".docx", ".doc", ".rtf", ".rtfd", ".odt", ".html", ".htm", ".webarchive"].contains(ext) else {
            throw Failure.unsupported
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atlantis-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("import\(ext)")
        try data.write(to: src)
        let out = try await run("/usr/bin/textutil", ["-convert", "html", "-stdout", src.path], timeout: 30)
        return ["html": String(decoding: out, as: UTF8.self)]
    }

    /// Runs a tool and returns its output; throws if it fails or takes longer than `timeout` seconds.
    private static func run(_ tool: String, _ args: [String], timeout: Double) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            guard process.terminationStatus == 0 else { throw Failure.noOutput }
            return data
        }.value
    }
}
