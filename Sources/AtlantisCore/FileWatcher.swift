import CoreServices
import Foundation

/// Calls `onChange` (on a background queue) when a file with this name changes inside a
/// folder, using FSEvents with a short built-in debounce. Nothing runs while nothing changes
/// (AGENTS.md "Idle = zero work"): no timers, no polling.
///
/// FSEvents sees in-place edits (Obsidian), atomic replaces (iCloud, Atlantis's own writes)
/// and deletes, which a plain file descriptor watch loses after the first replace.
public final class FileWatcher: @unchecked Sendable {
    private final class Box {
        /// nil: any file in the folder (or below it).
        let fileName: String?
        let handler: @Sendable () -> Void
        init(fileName: String?, handler: @escaping @Sendable () -> Void) {
            self.fileName = fileName
            self.handler = handler
        }
    }

    private var stream: FSEventStreamRef?
    private let box: Unmanaged<Box>
    private let queue = DispatchQueue(label: "au.lifeos.atlantis.filewatcher", qos: .utility)

    /// `folder` should exist. `latency` is the debounce in seconds.
    public convenience init?(folder: URL, fileName: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void) {
        self.init(folder: folder, match: fileName, latency: latency, onChange: onChange)
    }

    /// Any change to any file in `folder` or its sub-folders.
    public convenience init?(folder: URL, anyFile: Bool, latency: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.init(folder: folder, match: nil, latency: latency, onChange: onChange)
    }

    private init?(folder: URL, match fileName: String?, latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(fileName: fileName, handler: onChange))
        self.box = box
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { box.fileName == nil || ($0 as NSString).lastPathComponent == box.fileName }) { box.handler() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            box.release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            self.stream = nil
            return nil
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        box.release()
    }

    deinit { stop() }
}
