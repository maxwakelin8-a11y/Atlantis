import AtlantisCore
import Foundation
import Observation

/// Opens SEQTA files (course files, message attachments) for the Subjects and Messages pages:
/// downloads the file the first time (one request, then the hidden page is unloaded), keeps it in
/// `AppSupport.seqtaFiles`, and hands its address to Quick Look. Nothing is fetched until a click.
@MainActor @Observable
final class SeqtaFileOpener {
    /// The file Quick Look is showing (`.quickLookPreview` watches this).
    var preview: URL?
    /// UUIDs being downloaded now.
    private(set) var busy: Set<String> = []
    private(set) var error: String?

    @ObservationIgnored private let sync: SeqtaSync

    init(sync: SeqtaSync) { self.sync = sync }

    func open(uuid: String, name: String, source: SeqtaFileRequest.Source) {
        guard !busy.contains(uuid) else { return }
        busy.insert(uuid)
        error = nil
        Task {
            defer { busy.remove(uuid) }
            do {
                preview = try await sync.localFile(uuid: uuid, name: name, source: source)
            } catch let failure as SeqtaSyncError {
                error = failure.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func dismissError() { error = nil }
}

/// "1.2 MB" for a file size, or nothing when SEQTA didn't say.
func fileSizeText(_ bytes: Int?) -> String? {
    bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
}
