import Testing
@testable import AtlantisCore

@Suite struct PageTests {
    @Test func mainPagesGetSequentialShortcuts() {
        let numbers = Page.main.compactMap(\.shortcutNumber)
        #expect(numbers == (1...Page.main.count).map(String.init))
    }

    @Test func seqtaAndSettingsAreInTheBottomGroupWithoutNumbers() {
        #expect(Page.bottom == [.seqta, .settings])
        #expect(Page.settings.shortcutNumber == nil && Page.seqta.shortcutNumber == nil)
        #expect(!Page.main.contains(.seqta))
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
