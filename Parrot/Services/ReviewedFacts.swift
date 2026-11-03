import Foundation

extension ReviewedAnswerCatalog {
    enum KnowledgeMode: String, Codable { case wholeReply, reviewedFacts }

    /// A proposition is reviewed independently of a question or canned reply.
    /// Citation bytes never authorize use of neighboring, unreviewed claims.
    struct Fact: Codable {
        let id: String
        let claim: String
        let scopeKey: String
        let category: ReviewedScopeCategory
        let applicability: String
        let conditions: [String]
        let excludedScopes: [String]
        let requiredClientContext: [String]
        let evidence: Evidence
        let sourceSHA256: String
        let sourceRevision: String
        let documentedProductVersion: String?
        let authority: ReviewedSourceAuthority
        let review: Review

        var contentDigest: String {
            var parts = ["reviewed-fact-v1", claim, scopeKey, category.rawValue, applicability,
                         sourceSHA256, sourceRevision, documentedProductVersion ?? "", authority.rawValue]
            parts += [String(conditions.count)] + conditions
            parts += [String(excludedScopes.count)] + excludedScopes
            parts += [String(requiredClientContext.count)] + requiredClientContext
            parts += [evidence.sourceID, String(evidence.startUTF8), String(evidence.endUTF8), evidence.quote]
            return ReviewedAnswerCatalog.digest(parts)
        }
    }

    /// App-owned provenance, never accepted from the model's JSON.
    struct FactCitation: Codable, Equatable {
        let factID: String
        let factDigest: String
        let sourceID: String
        let sourceSHA256: String
        let sourceRevision: String
        let documentedProductVersion: String?
        let authority: ReviewedSourceAuthority
        let startUTF8: Int
        let endUTF8: Int
    }

    struct FactModelEntry {
        let sourceName: String
        let sourceRevision: String
        let documentedProductVersion: String?
        let authority: ReviewedSourceAuthority
        let claim: String
        let scopeKey: String
        let applicability: String
        let conditions: [String]
        let excludedScopes: [String]

        fileprivate func redacting(_ transform: (String) -> String) -> Self {
            Self(sourceName: sourceName, sourceRevision: sourceRevision,
                documentedProductVersion: documentedProductVersion, authority: authority,
                claim: transform(claim), scopeKey: scopeKey, applicability: transform(applicability),
                conditions: conditions.map(transform), excludedScopes: excludedScopes.map(transform))
        }
    }

    /// Created only by an admitted snapshot. Quotes stay local, while provider
    /// payloads contain separately reviewed claims and their conditions.
    struct FactContext {
        let revisionToken: String
        let citations: [FactCitation]
        let references: [KBReference]
        private let entries: [FactModelEntry]
        private let selectionQuestionDigest: String
        private let projectedQuestion: String

        fileprivate init(revisionToken: String, citations: [FactCitation],
                         references: [KBReference], entries: [FactModelEntry],
                         selectionQuestionDigest: String, projectedQuestion: String) {
            self.revisionToken = revisionToken
            self.citations = citations
            self.references = references
            self.entries = entries
            self.selectionQuestionDigest = selectionQuestionDigest
            self.projectedQuestion = projectedQuestion
        }

        var isEmpty: Bool { entries.isEmpty }
        var modelEvidence: [[String: Any]] {
            entries.enumerated().map { index, item in
                ["id": "p\(index)", "source": item.sourceName, "text": item.claim,
                 "evidence_kind": "reviewed_fact", "scope": item.scopeKey,
                 "applicability": item.applicability, "conditions": item.conditions,
                 "excluded_scopes": item.excludedScopes, "source_revision": item.sourceRevision,
                 "documented_product_version": item.documentedProductVersion ?? "",
                 "source_authority": item.authority.rawValue]
            }
        }

        func matches(question: String, selectionQuestion: String, references other: [KBReference]) -> Bool {
            projectedQuestion == question
                && selectionQuestionDigest == ReviewedAnswerCatalog.digest(["fact-question-v1", selectionQuestion])
                && references.count == entries.count && references.count == citations.count
                && references.count == other.count && zip(references, other).allSatisfy {
                    $0.documentName == $1.documentName && $0.note == $1.note && $0.text == $1.text
                }
        }

        func redacting(_ transform: (String) -> String) -> Self {
            Self(revisionToken: revisionToken, citations: citations,
                references: references.map { KBReference(documentName: $0.documentName,
                    note: $0.note, text: transform($0.text)) },
                entries: entries.map { $0.redacting(transform) },
                selectionQuestionDigest: selectionQuestionDigest, projectedQuestion: transform(projectedQuestion))
        }
    }

    static func containsDocumentedVersion(_ version: String, in text: String) -> Bool {
        guard !version.isEmpty else { return false }
        let optionalV = version.lowercased().hasPrefix("v") ? "" : "(?:v)?"
        let pattern = "(?<![A-Za-z0-9.])" + optionalV
            + NSRegularExpression.escapedPattern(for: version) + "(?![A-Za-z0-9.+-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    func validateFacts() throws {
        func require(_ pass: Bool, _ reason: String) throws {
            if !pass { throw ValidationError.invalid(reason) }
        }
        let units = facts ?? []
        try require(!units.isEmpty && units.count <= 4096, "invalid fact count")
        try require(Set(units.map(\.id)).count == units.count, "duplicate fact ID")
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        func bounded(_ text: String, words: Int) -> Bool {
            !text.isEmpty && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
                && text.split(whereSeparator: \.isWhitespace).count <= words
        }
        for fact in units {
            guard let source = byID[fact.evidence.sourceID] else {
                throw ValidationError.invalid("unknown fact source")
            }
            try require(bounded(fact.claim, words: 120) && bounded(fact.applicability, words: 160),
                        "invalid fact meaning or applicability")
            try require(fact.scopeKey.range(of: #"^[a-z][a-z0-9._-]{1,119}$"#,
                                           options: .regularExpression) != nil, "invalid fact scope")
            try require(fact.conditions.count <= 16 && fact.excludedScopes.count <= 16
                && Set(fact.conditions).count == fact.conditions.count
                && Set(fact.excludedScopes).count == fact.excludedScopes.count
                && (fact.conditions + fact.excludedScopes).allSatisfy { bounded($0, words: 80) },
                "invalid fact conditions or exclusions")
            try require(fact.requiredClientContext.isEmpty, "fact requires unverified client state")
            try require(fact.sourceSHA256 == source.sha256 && fact.sourceRevision == source.revision
                && fact.documentedProductVersion == source.productVersion
                && fact.authority == source.authority && fact.authority == fact.category.authority,
                "fact source scope differs")
            if let version = fact.documentedProductVersion {
                try require(bounded(version, words: 8) && version.count <= 80, "invalid fact version scope")
            }
            let bytes = Data(source.text.utf8), e = fact.evidence
            try require(e.startUTF8 >= 0 && e.endUTF8 > e.startUTF8 && e.endUTF8 <= bytes.count,
                        "invalid fact source range")
            try require(bounded(e.quote, words: 200)
                && bytes.subdata(in: e.startUTF8..<e.endUTF8) == Data(e.quote.utf8),
                "fact citation differs from exact source bytes")
            let digest = fact.contentDigest
            try require(fact.id == "f-" + digest.prefix(24)
                && fact.review.verdict == "PASS_SOURCE_FACT"
                && !fact.review.reviewer.isEmpty && !fact.review.reviewedAt.isEmpty
                && fact.review.digest == digest, "fact has no matching independent fact review")
        }
    }
}

extension ReviewedAnswerCatalog.Snapshot {
    /// Retrieval nominates facts, never approves an answer or proves corpus
    /// absence. Whole-reply aliases and forms are not used here.
    func factContext(question: String, displayedQuestion: String? = nil,
                     retrievedReferences: [KBReference], limit: Int = 12)
        -> ReviewedAnswerCatalog.FactContext {
        typealias Context = ReviewedAnswerCatalog.FactContext
        let questionDigest = ReviewedAnswerCatalog.digest(["fact-question-v1", question])
        let display = displayedQuestion ?? question
        let empty = Context(revisionToken: revisionToken, citations: [], references: [], entries: [],
                            selectionQuestionDigest: questionDigest, projectedQuestion: display)
        guard mode == .reviewedFacts, !question.isEmpty, question.count <= 4000, limit > 0 else { return empty }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let stop: Set<String> = ["the", "and", "for", "with", "how", "what", "does", "this", "that", "your", "can", "are"]
        func words(_ text: String) -> Set<String> {
            Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                             locale: Locale(identifier: "en_US_POSIX"))
                .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stop.contains($0) })
        }
        let asked = words(question)
        let regex = try? NSRegularExpression(pattern: #"\b[0-9]+\.[0-9]+(?:\.[0-9]+)?\b"#)
        let versions = Set((regex?.matches(in: question, range: NSRange(question.startIndex..., in: question)) ?? [])
            .compactMap { Range($0.range, in: question).map { String(question[$0]) } })
        // The importer glues Markdown headings onto paragraphs, changing only
        // whitespace. Normalize nomination inputs, never signed source bytes
        // or the exact quote returned in citations. Case and punctuation stay.
        func nominationText(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let retrievedBySource = Dictionary(grouping: retrievedReferences, by: \.documentName)
            .mapValues { $0.map { nominationText($0.text) } }
        var ranked: [(ReviewedAnswerCatalog.Fact, ReviewedAnswerCatalog.Source, Double)] = []
        for fact in facts {
            guard let source = byID[fact.evidence.sourceID],
                  versions.isEmpty || versions == Set([source.productVersion].compactMap { $0 }) else { continue }
            let overlap = Double(asked.intersection(words(
                ([fact.claim, fact.scopeKey, fact.applicability] + fact.conditions + fact.excludedScopes)
                    .joined(separator: " "))).count)
            let retrieved = retrievedBySource[source.name] ?? []
            let sourceMatch = !retrieved.isEmpty
            let quote = nominationText(fact.evidence.quote)
            let quoteMatch = !quote.isEmpty && retrieved.contains {
                !$0.isEmpty && ($0.contains(quote) || quote.contains($0))
            }
            guard overlap > 0 || quoteMatch else { continue }
            let score = overlap + (sourceMatch ? 0.5 : 0) + (quoteMatch ? 2 : 0)
            if score > 0 { ranked.append((fact, source, score)) }
        }
        ranked.sort { $0.2 == $1.2 ? $0.0.id < $1.0.id : $0.2 > $1.2 }
        var refs: [KBReference] = []
        var entries: [ReviewedAnswerCatalog.FactModelEntry] = []
        var citations: [ReviewedAnswerCatalog.FactCitation] = []
        var bytes = 0
        for (fact, source, _) in ranked {
            guard entries.count < min(limit, 12) else { break }
            let text = ([fact.claim, fact.scopeKey, fact.applicability, source.name,
                         source.revision, source.productVersion ?? ""] + fact.conditions + fact.excludedScopes)
                .joined(separator: "\n")
            let cost = text.utf8.count + 512
            guard bytes + cost <= 24_000 else { continue } // Never truncate a condition.
            bytes += cost
            let note = [source.provider, source.productVersion ?? source.revision]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            refs.append(KBReference(documentName: source.name, note: note, text: fact.evidence.quote))
            entries.append(.init(sourceName: source.name, sourceRevision: source.revision,
                documentedProductVersion: source.productVersion, authority: source.authority,
                claim: fact.claim, scopeKey: fact.scopeKey, applicability: fact.applicability,
                conditions: fact.conditions, excludedScopes: fact.excludedScopes))
            citations.append(.init(factID: fact.id, factDigest: fact.contentDigest,
                sourceID: source.id, sourceSHA256: source.sha256, sourceRevision: source.revision,
                documentedProductVersion: source.productVersion, authority: source.authority,
                startUTF8: fact.evidence.startUTF8, endUTF8: fact.evidence.endUTF8))
        }
        return Context(revisionToken: revisionToken, citations: citations, references: refs, entries: entries,
                       selectionQuestionDigest: questionDigest, projectedQuestion: display)
    }
}
