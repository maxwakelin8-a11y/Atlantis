import Foundation

/// WebKit's runtime stalls BetterSEQTA+'s module service worker: it loads, then stops answering
/// `runtime.sendMessage`, so the content script waits forever and SEQTA stays unstyled. The same
/// code run as an MV3 background page (which Safari supports) works. So the app loads a copy of
/// the build whose manifest swaps `service_worker` for a page that imports the same script.
/// The fork itself is untouched; the copy is refreshed whenever the build changes.
enum ExtensionStaging {
    private static let stampName = ".source-stamp"

    static func prepare(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let background = manifest["background"] as? [String: Any],
              let worker = background["service_worker"] as? String else {
            return source // Nothing to change.
        }

        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let staged = support.appendingPathComponent("Atlantis/BetterSEQTA", isDirectory: true)
        let stamp = try sourceStamp(source)
        let stampURL = staged.appendingPathComponent(stampName)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp { return staged }

        try? fm.removeItem(at: staged)
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staged)

        manifest["background"] = ["page": "background.html", "persistent": false]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: staged.appendingPathComponent("manifest.json"))
        let page = "<!DOCTYPE html>\n<meta charset=\"utf-8\">\n<script type=\"module\" src=\"\(worker)\"></script>\n"
        try page.write(to: staged.appendingPathComponent("background.html"), atomically: true, encoding: .utf8)
        try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        Log.seqta.info("Staged BetterSEQTA+ build")
        return staged
    }

    /// Changes whenever any file in the build is added, removed or modified.
    private static func sourceStamp(_ source: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var count = 0, bytes = 0
        var newest = 0.0
        if let e = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in e {
                let v = try url.resourceValues(forKeys: keys)
                count += 1
                bytes += v.fileSize ?? 0
                newest = max(newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return "\(source.path)|\(count)|\(bytes)|\(newest)"
    }
}
