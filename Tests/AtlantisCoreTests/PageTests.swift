import Testing
@testable import AtlantisCore

@Suite struct PageTests {
    @Test func mainPagesGetSequentialShortcuts() {
        let numbers = Page.main.compactMap(\.shortcutNumber)
        #expect(numbers == (1...Page.main.count).map(String.init))
    }

    @Test func settingsIsPinnedAndHasNoNumber() {
        #expect(Page.bottom == [.settings])
        #expect(Page.settings.shortcutNumber == nil)
    }

    @Test func todayComesFirst() {
        #expect(Page.main.first == .today)
    }

    @Test func everyPageHasATitleAndIcon() {
        for page in Page.allCases {
            #expect(!page.title.isEmpty)
            #expect(!page.systemImage.isEmpty)
        }
    }
}
