import Foundation
import Testing
@testable import AtlantisCore

@Suite struct KeychainTests {
    // A separate service so tests never touch the app's real items.
    let keychain = Keychain(service: "au.lifeos.atlantis.tests")

    @Test func saveReadReplaceDelete() throws {
        let account = "test-\(UUID().uuidString)"
        defer { try? keychain.delete(account) }
        #expect(try keychain.get(account) == nil)
        try keychain.set("first", for: account)
        #expect(try keychain.get(account) == "first")
        try keychain.set("second", for: account)
        #expect(try keychain.get(account) == "second")
        try keychain.delete(account)
        #expect(try keychain.get(account) == nil)
    }

    @Test func deletingAMissingItemIsFine() throws {
        try keychain.delete("never-saved-\(UUID().uuidString)")
    }
}

@Suite struct ContentRulesTests {
    private func rules(_ json: String) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private func matches(_ json: String, _ url: String) throws -> Bool {
        // Mimic WebKit: last matching rule wins; ignore-previous-rules clears a block.
        var blocked = false
        for rule in try rules(json) {
            let trigger = try #require(rule["trigger"] as? [String: String])
            let action = try #require(rule["action"] as? [String: String])
            let regex = try NSRegularExpression(pattern: try #require(trigger["url-filter"]))
            guard regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
            blocked = action["type"] == "block"
        }
        return blocked
    }

    @Test func noAlternationBecauseWebKitRejectsIt() throws {
        for json in [ContentRules.blockAllNetwork(), ContentRules.allowOnly(hosts: ["a.example.com"])] {
            for rule in try rules(json) {
                let trigger = try #require(rule["trigger"] as? [String: String])
                #expect(!(trigger["url-filter"] ?? "").contains("|"))
            }
        }
    }

    @Test func blockAllBlocksWebButNotLocal() throws {
        let json = ContentRules.blockAllNetwork()
        #expect(try matches(json, "https://example.com/"))
        #expect(try matches(json, "http://example.com/x"))
        #expect(try matches(json, "wss://example.com/socket"))
        #expect(try !matches(json, "atlantis-doc://doc/a.md"))
        #expect(try !matches(json, "data:text/plain,hi"))
    }

    @Test func allowOnlyLetsListedHostsThrough() throws {
        let json = ContentRules.allowOnly(hosts: ["learn.example.edu.au", "microsoftonline.com"])
        #expect(try !matches(json, "https://learn.example.edu.au/home"))
        #expect(try !matches(json, "https://login.microsoftonline.com/x"))
        #expect(try matches(json, "https://example.edu.au/"))
        #expect(try matches(json, "https://learn.example.edu.au.evil.com/"))
        #expect(try matches(json, "https://evilmicrosoftonline.com/"))
    }
}

@Suite struct ProcessStatsTests {
    @Test func readsNumbers() throws {
        let stats = try #require(ProcessStats.current())
        #expect(stats.footprintBytes > 0)
        #expect(stats.cpuSeconds > 0)
        let uptime = try #require(ProcessStats.secondsSinceLaunch())
        #expect(uptime > 0 && uptime < 3600)
    }

    @Test func cpuPercentMaths() {
        let a = ProcessStats(cpuSeconds: 1, footprintBytes: 0, wakeups: 10, takenAt: Date(timeIntervalSince1970: 0))
        let b = ProcessStats(cpuSeconds: 1.5, footprintBytes: 0, wakeups: 30, takenAt: Date(timeIntervalSince1970: 2))
        #expect(b.cpuPercent(since: a) == 25)
        #expect(b.wakeupsPerSecond(since: a) == 10)
    }
}
