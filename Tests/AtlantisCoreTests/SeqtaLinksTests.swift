import Foundation
import Testing
@testable import AtlantisCore

@Suite struct SeqtaLinksTests {
    @Test func addsHttpsAndSlash() {
        #expect(SeqtaLinks.homeURL(from: "learn.example.edu.au")?.absoluteString == "https://learn.example.edu.au/")
    }

    @Test func keepsAFullAddress() {
        #expect(SeqtaLinks.homeURL(from: " https://Learn.Example.edu.au/#?page=/home ")?.absoluteString
            == "https://learn.example.edu.au/#?page=/home")
    }

    @Test func rejectsJunk() {
        #expect(SeqtaLinks.homeURL(from: "") == nil)
        #expect(SeqtaLinks.homeURL(from: "not a url") == nil)
        #expect(SeqtaLinks.homeURL(from: "ftp://learn.example.edu.au") == nil)
        #expect(SeqtaLinks.homeURL(from: "localhost") == nil)
    }

    @Test func seqtaAndLoginStayInApp() {
        let host = "learn.example.edu.au"
        #expect(SeqtaLinks.opensInApp(URL(string: "https://learn.example.edu.au/x")!, seqtaHost: host))
        #expect(SeqtaLinks.opensInApp(URL(string: "https://login.microsoftonline.com/a")!, seqtaHost: host))
        #expect(SeqtaLinks.opensInApp(URL(string: "https://betterseqta.org")!, seqtaHost: host))
    }

    @Test func otherSitesOpenInBrowser() {
        let host = "learn.example.edu.au"
        #expect(!SeqtaLinks.opensInApp(URL(string: "https://youtube.com/watch")!, seqtaHost: host))
        #expect(!SeqtaLinks.opensInApp(URL(string: "https://evilmicrosoft.com")!, seqtaHost: host))
        #expect(!SeqtaLinks.opensInApp(URL(string: "https://example.edu.au")!, seqtaHost: host))
    }

    @Test func webSchemes() {
        #expect(SeqtaLinks.isWebScheme("https"))
        #expect(SeqtaLinks.isWebScheme("webkit-extension"))
        #expect(!SeqtaLinks.isWebScheme("mailto"))
        #expect(!SeqtaLinks.isWebScheme("msteams"))
    }
}
