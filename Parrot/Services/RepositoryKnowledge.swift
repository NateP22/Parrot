import Foundation
import CryptoKit

/// A read-only export of original GitHub blobs, never model-authored facts.
/// The exporter verifies commit/tree membership through GitHub. The importer
/// verifies package integrity; it does not authenticate an arbitrary third-party
/// package or prove what version a customer has installed.
struct RepositoryKnowledge: Codable {
    let schemaVersion: Int
    let repository: String
    let requestedRef: String
    let commit: String
    let files: [File]

    struct File: Codable {
        let path: String
        let blob: String
        let sha256: String
        let text: String
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let reason): return "Repository source rejected: " + reason }
        }
    }

    static let maximumBytes = 24 * 1024 * 1024
    static let maximumFileBytes = 512 * 1024

    /// Allow runtime source/config only. Secret, build, dependency and test data
    /// never become question evidence. Docs use the separate secondary route.
    static func permits(path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"),
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
              path.components(separatedBy: "/").allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        let parts = path.lowercased().components(separatedBy: "/")
        let excluded: Set<String> = ["node_modules", "vendor", "dist", "build", ".build", "coverage",
            "test", "tests", "__tests__", "fixtures", "docs", "documentation", "__snapshots__",
            "generated", "logs", "tmp", "cache", "certificates", "credentials", "secrets"]
        guard !parts.contains(where: { $0.hasPrefix(".") || excluded.contains($0) }),
              let name = parts.last, !name.contains("secret"), !name.contains("credential"),
              !name.contains("private-key"), !name.hasSuffix(".min.js"),
              !name.contains(".test."), !name.contains(".spec.") else { return false }
        let credentialName = name.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        guard !["token", "apikey", "privatekey", "password", "keychain"].contains(where: credentialName.contains) else { return false }
        return ["js", "jsx", "ts", "tsx", "swift", "json", "html", "css", "scss", "vue", "svelte",
                "py", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "mm", "sql", "xml"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func gitBlob(_ data: Data) -> String {
        let object = Data("blob \(data.count)\0".utf8) + data
        return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ data: Data) throws -> RepositoryKnowledge {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.invalid("package size") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1,
              result.repository.range(of: #"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              result.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              !result.requestedRef.isEmpty, result.requestedRef.utf8.count <= 256,
              !result.files.isEmpty, result.files.count <= 2000 else { throw Failure.invalid("manifest") }
        var paths = Set<String>()
        var total = 0
        for file in result.files {
            let bytes = Data(file.text.utf8)
            total += bytes.count
            guard permits(path: file.path), paths.insert(file.path.lowercased()).inserted,
                  !bytes.isEmpty, bytes.count <= maximumFileBytes, total <= maximumBytes,
                  !file.text.contains("\0"), file.blob == gitBlob(bytes),
                  file.sha256 == digest(bytes) else { throw Failure.invalid("file path, size or digest") }
            // Fail closed on common credential material even in a tracked source
            // file. No redaction that silently changes the cited blob is allowed.
            guard !containsCredential(file.text) else { throw Failure.invalid("credential material") }
        }
        return result
    }

    static func containsCredential(_ text: String) -> Bool {
        let signatures = #"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|AIza[A-Za-z0-9_-]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16}|-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#
        let assignments = #"(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|client[_-]?secret)["']?\s*[:=]\s*["'][A-Za-z0-9_+/=\-]{12,}["']"#
        return [signatures, assignments].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Stable across JSON formatting, changes with the complete code inventory.
    var revision: String {
        Self.digest(Data(([repository, commit] + files.sorted { $0.path < $1.path }
            .map { $0.path + "\0" + $0.blob + "\0" + $0.sha256 }).joined(separator: "\n").utf8))
    }

    struct Passage {
        let text: String
        let citation: RepositoryCitation
        var searchText: String { citation.path + "\n" + text }
    }

    /// Preserve complete lines, CRLF and short statements. Adjacent windows
    /// overlap so a branch condition is not automatically cut off at its body.
    func passages(linesPerChunk: Int = 48, overlap: Int = 12) -> [Passage] {
        let width = max(2, linesPerChunk), step = max(1, width - max(0, min(width - 1, overlap)))
        let token = revision
        return files.flatMap { file -> [Passage] in
            var lines = file.text.components(separatedBy: "\n")
            let finalNewline = file.text.utf8.last == 0x0A
            // A terminal newline terminates the last GitHub line; it does not
            // create another numbered line for a citation.
            if finalNewline { lines.removeLast() }
            return stride(from: 0, to: lines.count, by: step).compactMap { first in
                let last = min(lines.count, first + width)
                let text = lines[first..<last].joined(separator: "\n")
                    + (last < lines.count || finalNewline ? "\n" : "")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Passage(text: text, citation: RepositoryCitation(repository: repository,
                    commit: commit, path: file.path, blob: file.blob, sha256: file.sha256,
                    startLine: first + 1, endLine: last, revision: token))
            }
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}

/// Constructed by the app from verified source bytes, never model URLs.
struct RepositoryCitation: Codable, Equatable {
    let repository: String
    let commit: String
    let path: String
    let blob: String
    let sha256: String
    let startLine: Int
    let endLine: Int
    let revision: String

    var sourceName: String { repository + "/" + path }
    var label: String { "\(path):\(startLine)–\(endLine) @ \(commit.prefix(8))" }
    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/blob/\(commit)/\(path)"
        components.fragment = "L\(startLine)-L\(endLine)"
        return components.url!
    }
}
