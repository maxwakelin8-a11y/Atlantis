// swift-tools-version:6.0
import Foundation
import PackageDescription

// Swift Testing ships with the Command Line Tools but isn't on the default search path
// when Xcode isn't installed. Point the test target at it when it's there.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsCLTTesting = FileManager.default.fileExists(atPath: "\(cltFrameworks)/Testing.framework")
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

let testingSwiftFlags: [SwiftSetting] = needsCLTTesting ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testingLinkerFlags: [LinkerSetting] = needsCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-framework", "Testing",
                     "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                     "-Xlinker", "-rpath", "-Xlinker", cltLibs])]
    : []

let package = Package(
    name: "Atlantis",
    platforms: [.macOS("15.4")],
    targets: [
        // Logic with no UI, so it can be tested on its own.
        .target(name: "AtlantisCore", path: "Sources/AtlantisCore"),
        .executableTarget(
            name: "Atlantis",
            dependencies: ["AtlantisCore"],
            path: "Sources/Atlantis",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        // Tests are an executable, not a .testTarget: with only the Command Line Tools,
        // `swift test` builds Swift Testing suites but never runs them. Run scripts/test.sh.
        .executableTarget(
            name: "AtlantisTests",
            dependencies: ["AtlantisCore"],
            path: "Tests",
            exclude: ["AtlantisCoreTests/Fixtures"], // made-up SEQTA JSON, read by path in the tests
            swiftSettings: testingSwiftFlags,
            linkerSettings: testingLinkerFlags
        ),
    ]
)
