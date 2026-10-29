import Foundation

/// Keeps the decision to require reviewed answers across a restart. Losing or
/// rejecting a library cannot silently restore free-form product answers.
struct ReviewedAnswerStore {
    let url: URL
    var requiredURL: URL { url.appendingPathExtension("required") }
    private static let requiredMarker = Data("parrot-reviewed-answers-required-v1\n".utf8)

    var isConfigured: Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: requiredURL.path)
    }

    func requireReviewedAnswers() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.requiredMarker.write(to: requiredURL, options: .atomic)
        guard try Data(contentsOf: requiredURL) == Self.requiredMarker else {
            throw ReviewedAnswerCatalog.ValidationError.invalid("reviewed-mode readback differs")
        }
    }

    func load() throws -> ReviewedAnswerCatalog? {
        guard isConfigured else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReviewedAnswerCatalog.ValidationError.invalid("library is missing; re-import the reviewed library")
        }
        // Existing libraries predate the intent marker. Migrate their intent
        // before decoding, so later loss/corruption cannot re-enable generation.
        try requireReviewedAnswers()
        return try ReviewedAnswerCatalog.decode(Self.readData(at: url))
    }

    func install(_ data: Data) throws -> ReviewedAnswerCatalog {
        // Intent is durable before validation, including a first invalid import.
        try requireReviewedAnswers()
        let catalog = try ReviewedAnswerCatalog.decode(data)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Self.readData(at: url)
            if previous != data {
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("reviewed-answers-backup-\(UUID().uuidString).json")
                try previous.write(to: backup, options: .atomic)
                guard try Data(contentsOf: backup) == previous else {
                    throw ReviewedAnswerCatalog.ValidationError.invalid("library backup readback differs")
                }
            }
        }
        try data.write(to: url, options: .atomic)
        let readback = try Self.readData(at: url)
        guard readback == data else {
            throw ReviewedAnswerCatalog.ValidationError.invalid("saved library readback differs")
        }
        _ = try ReviewedAnswerCatalog.decode(readback)
        return catalog
    }

    static func readData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 16 * 1024 * 1024 else {
            throw ReviewedAnswerCatalog.ValidationError.invalid("file is too large or its size is unknown")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
