// Runs the Swift Testing suites. `swift test` with only the Command Line Tools builds the
// tests but doesn't run them, so `scripts/test.sh` runs this instead.
import Testing

await Testing.__swiftPMEntryPoint() as Never
