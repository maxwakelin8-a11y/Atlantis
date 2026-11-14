import AppKit

/// Spelling and grammar for the Docs page, using the Mac's own checker (`NSSpellChecker`): the same
/// dictionary and language (e.g. Australian English) as every other Mac app. It runs on this Mac,
/// so it's fast, free and works offline; nothing is sent anywhere.
///
/// The page sends paragraphs (`{id, text}`); each comes back as a list of issues in the Writer's
/// `ProofIssue` shape: `kind`, `quote`, `at` (UTF-16 offset, as JavaScript counts), `fix`, `alts`, `note`.
enum SpellCheck {
    /// One tag for the app's life, so "ignore" choices made by the checker stay consistent.
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    /// Most a single call checks (the page sends small batches; this is only a guard).
    static let maxParagraphs = 400
    static let maxChars = 20_000

    struct Issue: Sendable, Equatable {
        var kind: String
        var quote: String
        var at: Int
        var fix: String?
        var alts: [String]
        var note: String

        var json: [String: Any] {
            ["kind": kind, "quote": quote, "at": at, "fix": fix ?? NSNull(), "alts": alts, "note": note]
        }
    }

    /// Issues per paragraph id, ready for the page.
    static func check(_ paragraphs: [(id: String, text: String)]) async -> [String: [[String: Any]]] {
        await issues(paragraphs).mapValues { $0.map(\.json) }
    }

    static func issues(_ paragraphs: [(id: String, text: String)]) async -> [String: [Issue]] {
        var out: [String: [Issue]] = [:]
        await withTaskGroup(of: (String, [Issue]).self) { group in
            for p in paragraphs.prefix(maxParagraphs) where !p.text.isEmpty && p.text.utf16.count <= maxChars {
                group.addTask { (p.id, await issues(in: p.text)) }
            }
            for await (id, list) in group { out[id] = list }
        }
        return out
    }

    static func issues(in text: String) async -> [Issue] {
        let ns = text as NSString
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        return await withCheckedContinuation { done in
            NSSpellChecker.shared.requestChecking(of: text, range: NSRange(location: 0, length: ns.length), types: types,
                                    options: nil, inSpellDocumentWithTag: tag) { _, results, _, _ in
                let checker = NSSpellChecker.shared
                var list: [Issue] = []
                for r in results {
                    if r.resultType == .spelling {
                        let word = ns.substring(with: r.range)
                        // nil language = the checker's current one (the Mac's, e.g. en_AU).
                        let guesses = checker.guesses(forWordRange: r.range, in: text, language: nil,
                                                      inSpellDocumentWithTag: tag) ?? []
                        list.append(Issue(kind: "spelling", quote: word, at: r.range.location, fix: guesses.first,
                                          alts: Array(guesses.dropFirst().prefix(3)),
                                          note: guesses.isEmpty ? "Not in the dictionary." : ""))
                    } else if r.resultType == .grammar {
                        for detail in r.grammarDetails ?? [] {
                            guard let range = (detail["NSGrammarRange"] as? NSValue)?.rangeValue else { continue }
                            // Detail ranges are relative to the result (a sentence).
                            let abs = NSRange(location: r.range.location + range.location, length: range.length)
                            guard abs.length > 0, NSMaxRange(abs) <= ns.length else { continue }
                            let fixes = detail["NSGrammarCorrections"] as? [String] ?? []
                            let note = (detail["NSGrammarUserDescription"] as? String ?? "")
                                .replacingOccurrences(of: "  ", with: " ")
                            list.append(Issue(kind: "grammar", quote: ns.substring(with: abs), at: abs.location,
                                              fix: fixes.first, alts: Array(fixes.dropFirst().prefix(3)), note: note))
                        }
                    }
                }
                done.resume(returning: list)
            }
        }
    }
}
