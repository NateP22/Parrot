import Foundation
import CryptoKit

/// Whole, source-reviewed replies. The live model may select an ID, never
/// author or combine their factual wording. Source review is not app acceptance.
struct ReviewedAnswerCatalog: Codable {
    static let fileFormat = "parrot-reviewed-answers-v2"
    /// Public verification material only. The local signing key is never
    /// bundled with the app, source repository, CI or knowledge library.
    static let verificationKeyBase64 = "4EJ5i69h3df2DchnTdF/eK7ub9B1yP7sj2GOqxFzqVo="
    let format: String
    let sources: [Source]
    let answers: [Answer]
    private var validated = false
    private enum CodingKeys: String, CodingKey { case format, sources, answers }

    struct Source: Codable {
        let id: String
        let name: String
        let provider: String
        let authority: ReviewedSourceAuthority
        let revision: String
        let productVersion: String?
        let urls: [String]
        let sha256: String
        let text: String

        var identityDigest: String {
            ReviewedAnswerCatalog.digest(["source-v2", name, provider, authority.rawValue, revision,
                productVersion ?? "", sha256, String(urls.count)] + urls)
        }
    }

    /// Byte offsets refer to the exact UTF-8 source, start inclusive/end exclusive.
    struct Evidence: Codable {
        let sourceID: String
        let startUTF8: Int
        let endUTF8: Int
        let quote: String
    }

    struct Review: Codable {
        let verdict: String
        let reviewer: String
        let reviewedAt: String
        let digest: String
    }

    /// Only these strings go to the selector; the original reviewed unit and
    /// evidence stay local. Privacy redaction changes this projection only.
    struct SelectionEntry {
        let id: String
        let reply: String
        let applicability: String
        let excludedScopes: [String]
        let scopeKey: String
        let scopeCategory: String
        let sourceAuthority: String
        let supportedForms: [String]
    }

    struct Answer: Codable {
        enum Kind: String, Codable { case instruction, behavior, uncertainty, clarification }
        let id: String
        let kind: Kind
        let title: String
        let reply: String
        let applicability: String
        let excludedScopes: [String]
        let searchTerms: [String]
        /// Unsupported until an app-owned client-state verifier exists. Conditions
        /// needed by admitted replies must be stated in their reviewed wording.
        let requiredClientContext: [String]
        let scope: ReviewedQuestionScope
        let supportedForms: [ReviewedQuestionForm]
        let evidence: [Evidence]
        let review: Review

        var contentDigest: String {
            var parts = ["answer-v2", kind.rawValue, title, reply, applicability,
                String(excludedScopes.count)] + excludedScopes
            parts += [String(searchTerms.count)] + searchTerms
            parts += [String(requiredClientContext.count)] + requiredClientContext
            parts += scope.digestParts
            parts += [String(supportedForms.count)] + supportedForms.map(\.rawValue)
            parts += [String(evidence.count)]
            for item in evidence {
                parts += [item.sourceID, String(item.startUTF8), String(item.endUTF8), item.quote]
            }
            return ReviewedAnswerCatalog.digest(parts)
        }
    }

    struct Snapshot {
        let sources: [Source]
        let answers: [Answer]
        let admissionIssues: [String]
        /// Retain signed routing definitions even when their source is out of play.
        /// A missing second topic must not turn a compound question into a partial answer.
        private let scopeDefinitions: [ReviewedQuestionScope]

        var revisionToken: String {
            ReviewedAnswerCatalog.digest(["snapshot-v2", String(sources.count)]
                + sources.map(\.id).sorted() + [String(answers.count)] + answers.map(\.id).sorted()
                + [String(scopeDefinitions.count)] + scopeDefinitions.map { ReviewedAnswerCatalog.digest($0.digestParts) }.sorted())
        }

        fileprivate init(sources: [Source], answers: [Answer], admissionIssues: [String],
                         scopeDefinitions: [ReviewedQuestionScope] = []) {
            self.sources = sources
            self.answers = answers
            self.admissionIssues = admissionIssues
            self.scopeDefinitions = scopeDefinitions
        }

        static func unavailable(_ reason: String) -> Snapshot {
            Snapshot(sources: [], answers: [], admissionIssues: [reason])
        }

        func questionRequirement(_ question: String) -> ReviewedQuestionRequirement {
            guard !question.isEmpty, question.count <= 4000,
                  !ReviewedQuestionScope.containsQuotedQuestion(question) else { return .ambiguous }
            let forms = ReviewedQuestionForm.forms(in: question)
            guard !forms.isEmpty else { return .ambiguous }
            let matches = scopeDefinitions.filter { $0.matches(question) }
            guard matches.count == 1, let scope = matches.first else { return .ambiguous }
            return .matched(key: scope.key, category: scope.category, forms: forms)
        }

        /// Recomputed from the canonical snapshot, not a caller's candidate array
        /// or a scope label returned by the model.
        func permitsAnswer(for answerID: String, question: String) -> Bool {
            guard let answer = answers.first(where: { $0.id == answerID }) else { return false }
            return permits(answer, requirement: questionRequirement(question))
                && permitsVersions(answer, requested: Self.versionNumbers(question))
        }

        private func permits(_ answer: Answer, requirement: ReviewedQuestionRequirement) -> Bool {
            guard case .matched(let key, let category, let forms) = requirement,
                  answer.scope.key == key, answer.scope.category == category,
                  forms.isSubset(of: Set(answer.supportedForms)) else { return false }
            let used = Set(answer.evidence.map(\.sourceID))
            let evidenceSources = sources.filter { used.contains($0.id) }
            return evidenceSources.count == used.count && !used.isEmpty
                && evidenceSources.allSatisfy { $0.authority == category.authority }
        }

        /// Retrieval narrows the choice, never certifies its relevance. The live
        /// selector must still reject an unanswerable or differently scoped question.
        func candidates(question: String, referenceNames: Set<String>, limit: Int = 12) -> [Answer] {
            let asked = ReviewedAnswerCatalog.tokens(question)
            guard !asked.isEmpty, limit > 0 else { return [] }
            let requestedVersions = Self.versionNumbers(question)
            let requirement = questionRequirement(question)
            let sourceNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.name) })
            var ranked: [(answer: Answer, score: Double)] = []
            for answer in answers {
                guard permits(answer, requirement: requirement),
                      permitsVersions(answer, requested: requestedVersions) else { continue }
                let words = ReviewedAnswerCatalog.tokens(([answer.title, answer.reply,
                    answer.applicability] + answer.searchTerms).joined(separator: " "))
                let overlap = Double(asked.intersection(words).count)
                let matchesReference = answer.evidence.contains { item in
                    guard let name = sourceNames[item.sourceID] else { return false }
                    return referenceNames.contains(name)
                }
                let score: Double = overlap + (matchesReference ? 0.5 : 0.0)
                if score > 0 { ranked.append((answer, score)) }
            }
            ranked.sort {
                $0.score == $1.score ? $0.answer.id < $1.answer.id : $0.score > $1.score
            }
            return ranked.prefix(limit).map { $0.answer }
        }

        func permitsVersion(for answerID: String, question: String) -> Bool {
            guard let answer = answers.first(where: { $0.id == answerID }) else { return false }
            return permitsVersions(answer, requested: Self.versionNumbers(question))
        }

        private func permitsVersions(_ answer: Answer, requested: Set<String>) -> Bool {
            guard !requested.isEmpty, answer.kind == .instruction || answer.kind == .behavior else { return true }
            let used = Set(answer.evidence.map(\.sourceID))
            let documented = Set(sources.filter { used.contains($0.id) }.compactMap(\.productVersion))
            return requested.isSubset(of: documented)
        }

        private static func versionNumbers(_ text: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: "\\b[0-9]+\\.[0-9]+\\.[0-9]+\\b") else { return [] }
            return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            })
        }

        func selectionEntries(for candidates: [Answer]) -> [SelectionEntry] {
            candidates.map { SelectionEntry(id: $0.id, reply: $0.reply,
                applicability: $0.applicability, excludedScopes: $0.excludedScopes,
                scopeKey: $0.scope.key, scopeCategory: $0.scope.category.rawValue,
                sourceAuthority: $0.scope.category.authority.rawValue,
                supportedForms: $0.supportedForms.map(\.rawValue)) }
        }

        func references(for answerID: String) -> [KBReference] {
            guard let answer = answers.first(where: { $0.id == answerID }) else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
            return answer.evidence.compactMap { item in
                guard let source = byID[item.sourceID] else { return nil }
                let note = [source.provider, source.productVersion ?? source.revision]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                return KBReference(documentName: source.name, note: note, text: item.quote)
            }
        }
    }

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let reason): "Reviewed answers: \(reason)" }
        }
    }

    static func decode(_ data: Data) throws -> ReviewedAnswerCatalog {
        guard data.count <= 16 * 1024 * 1024 else { throw ValidationError.invalid("file is too large") }
        struct Envelope: Decodable { let format: String; let payload: String; let signature: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == "parrot-reviewed-answers-signed-v2",
              let payload = Data(base64Encoded: envelope.payload), payload.count <= 12 * 1024 * 1024,
              let signature = Data(base64Encoded: envelope.signature),
              let publicBytes = Data(base64Encoded: verificationKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicBytes),
              publicKey.isValidSignature(signature, for: payload) else {
            throw ValidationError.invalid("missing or invalid trusted catalog signature")
        }
        var result = try JSONDecoder().decode(Self.self, from: payload)
        try result.validate()
        return result
    }

    private mutating func validate() throws {
        validated = false
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ValidationError.invalid(reason) }
        }
        try require(format == Self.fileFormat, "unknown file format")
        try require(!sources.isEmpty && !answers.isEmpty, "empty library")
        try require(Set(sources.map(\.id)).count == sources.count, "duplicate source ID")
        try require(Set(sources.map(\.name)).count == sources.count, "ambiguous document names")
        try require(Set(answers.map(\.id)).count == answers.count, "duplicate answer ID")
        for source in sources {
            try require((source.name as NSString).lastPathComponent == source.name
                && !source.name.isEmpty, "invalid source name")
            try require(!source.provider.isEmpty && !source.revision.isEmpty, "missing source provenance")
            try require(KBDocument.validContentSHA256(source.sha256) == source.sha256
                && Self.sha256(Data(source.text.utf8)) == source.sha256, "source text hash mismatch")
            try require(source.id == "s-" + source.identityDigest, "source identity changed")
        }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var scopes: [String: ReviewedQuestionScope] = [:]
        for answer in answers {
            try require(answer.scope.isValid, "invalid reviewed question scope")
            try require(!answer.supportedForms.isEmpty
                && Set(answer.supportedForms).count == answer.supportedForms.count, "invalid supported question forms")
            try require(!answer.supportedForms.contains(.clientState)
                || answer.kind == .clarification || answer.kind == .uncertainty, "unverified client-state scope for a factual reply")
            if let previous = scopes[answer.scope.key] {
                try require(previous == answer.scope, "conflicting scope definitions")
            } else { scopes[answer.scope.key] = answer.scope }
            let digest = answer.contentDigest
            try require(answer.id == "a-" + digest.prefix(24), "answer identity changed")
            try require(answer.review.verdict == "PASS_SOURCE_ONLY"
                && !answer.review.reviewer.isEmpty && !answer.review.reviewedAt.isEmpty
                && answer.review.digest == digest, "answer has no matching source-review receipt")
            try require(answer.requiredClientContext.isEmpty, "answer requires unverified client state")
            try require(Self.isConcise(answer.reply), "reply is not a complete short unit")
            try require(!answer.title.isEmpty && answer.title.split(whereSeparator: \.isWhitespace).count <= 8,
                "invalid answer title")
            try require(!answer.applicability.isEmpty, "missing answer scope")
            try require(answer.evidence.count <= 3, "too many evidence excerpts")
            try require(!answer.evidence.isEmpty, "library reply has no source scope")
            if answer.kind == .uncertainty {
                try require(answer.reply.hasPrefix("I haven't verified that."), "uncertainty is not explicit")
            }
            for evidence in answer.evidence {
                guard let source = byID[evidence.sourceID] else {
                    throw ValidationError.invalid("unknown evidence source")
                }
                try require(source.authority == answer.scope.category.authority, "scope authority mismatch")
                let bytes = Data(source.text.utf8)
                try require(evidence.startUTF8 >= 0 && evidence.endUTF8 > evidence.startUTF8
                    && evidence.endUTF8 <= bytes.count, "invalid evidence range")
                try require(!evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && evidence.quote.split(whereSeparator: \.isWhitespace).count <= 200,
                    "invalid evidence excerpt")
                try require(bytes.subdata(in: evidence.startUTF8..<evidence.endUTF8) == Data(evidence.quote.utf8),
                    "evidence is not exact source text")
                if let version = source.productVersion, !version.isEmpty {
                    // The catalog's version is not evidence of the client's version.
                    // Keep the source-version scope in the spoken wording itself.
                    try require(answer.reply.contains(version), "reply omits its product-version scope")
                }
            }
        }
        validated = true
    }

    /// A configured library never falls through to unreviewed generation just
    /// because the imported source is old, unknown, changed, or out of play.
    func admitted(documents: [KBDocument], folders: [KBFolder], profileID: UUID?) -> Snapshot {
        guard validated else { return .unavailable("Library has not passed validation") }
        let current = Dictionary(grouping: documents, by: \.name)
        var acceptedSources: [Source] = []
        var issues: [String] = []
        for source in sources {
            guard let matching = current[source.name], matching.count == 1,
                  let document = matching.first, document.effectiveScope(in: folders).allows(profileID),
                  document.contentSHA256 == source.sha256 else {
                issues.append("Source unavailable, changed, unknown or out of scope: " + source.name)
                continue
            }
            acceptedSources.append(source)
        }
        let sourceIDs = Set(acceptedSources.map(\.id))
        let eligible = answers.filter { $0.evidence.allSatisfy { sourceIDs.contains($0.sourceID) } }
        let definitions = Dictionary(grouping: answers.map(\.scope), by: \.key)
            .values.compactMap(\.first).sorted { $0.key < $1.key }
        return Snapshot(sources: acceptedSources, answers: eligible, admissionIssues: issues, scopeDefinitions: definitions)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Length-prefixed UTF-8 avoids cross-language JSON escaping/canonicalization
    /// differences. Counts are bytes; array counts are explicit digest parts.
    static func digest(_ parts: [String]) -> String {
        var data = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            data.append(Data("\(bytes.count):".utf8))
            data.append(bytes)
        }
        return sha256(data)
    }

    static func isConcise(_ reply: String) -> Bool {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == reply, !text.isEmpty, !text.contains("\n"),
              text.split(whereSeparator: \.isWhitespace).count <= 30,
              !text.contains("{") && !text.contains("}") && !text.contains("```") else { return false }
        var sentences = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: .bySentences) { _, _, _, _ in sentences += 1 }
        return sentences > 0 && sentences <= 2
    }

    private static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "how", "what", "does", "this", "that", "your", "can", "are"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) })
    }
}
