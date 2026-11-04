import Foundation
import NaturalLanguage

/// Hides personal details before text goes to a cloud AI and puts them back
/// in what comes back: emails, phone numbers, card numbers (Luhn-checked),
/// IBANs, and optionally people's names (Apple's on-device name tagger).
/// The AI sees "[EMAIL_1]"; the user sees the real address.
///
/// One instance per request, so the same value maps to the same placeholder
/// across a request and its response. Only used for cloud brains, and only
/// when Settings → Privacy → "Hide personal details from cloud AI" is on.
struct Redactor {

    static let enabledKey = "redactCloud"
    static let namesKey = "redactNames"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var hideNames: Bool = false

    /// placeholder → original
    private(set) var originals: [String: String] = [:]
    /// original → placeholder
    private var placeholders: [String: String] = [:]
    private var counters: [String: Int] = [:]

    init(hideNames: Bool = UserDefaults.standard.bool(forKey: Redactor.namesKey)) {
        self.hideNames = hideNames
    }

    private static func regex(_ p: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p)
    }

    private static let email = regex(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let iban = regex(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#)
    private static let card = regex(#"(?<![\d.])(?:\d[ \-]?){12,18}\d(?![\d.])"#)
    private static let phone = regex(#"(?<![\w:/.\[])\+?\(?\d[\d\s().\-]{7,}\d(?![\w:\]])"#)

    /// `text` with sensitive values replaced by stable placeholders.
    mutating func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        out = replace(Self.email, in: out, kind: "EMAIL") { _ in true }
        out = replace(Self.iban, in: out, kind: "IBAN") { _ in true }
        out = replace(Self.card, in: out, kind: "CARD") { Self.luhn($0) }
        out = replace(Self.phone, in: out, kind: "PHONE") { match in
            let digits = match.filter(\.isNumber).count
            return digits >= 9 && digits <= 15
        }
        if hideNames { out = replaceNames(in: out) }
        return out
    }

    /// Puts the originals back.
    func restore(_ text: String) -> String {
        guard !originals.isEmpty, text.contains("[") else { return text }
        var out = text
        // Longest first, so [PHONE_12] isn't hit by [PHONE_1].
        for (placeholder, original) in originals.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: placeholder, with: original)
        }
        return out
    }

    private mutating func placeholder(for original: String, kind: String) -> String {
        if let existing = placeholders[original] { return existing }
        let n = (counters[kind] ?? 0) + 1
        counters[kind] = n
        let p = "[\(kind)_\(n)]"
        placeholders[original] = p
        originals[p] = original
        return p
    }

    private mutating func replace(_ regex: NSRegularExpression, in text: String, kind: String,
                                  accept: (String) -> Bool) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for m in matches.reversed() {
            let value = ns.substring(with: m.range)
            guard accept(value), !value.hasPrefix("[") else { continue }
            result.replaceCharacters(in: m.range, with: placeholder(for: value, kind: kind))
        }
        return result as String
    }

    private mutating func replaceNames(in text: String) -> String {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { ranges.append(range) }
            return true
        }
        guard !ranges.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for range in ranges.reversed() {
            let name = String(text[range])
            // Not our own placeholders, not one-letter noise.
            guard name.count > 1, !name.contains("_") else { continue }
            result.replaceCharacters(in: NSRange(range, in: text), with: placeholder(for: name, kind: "NAME"))
        }
        return result as String
    }

    /// Card-number checksum, so order numbers and IDs aren't hidden.
    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}

// MARK: - Requests and results

extension Redactor {

    /// A live-analysis request with every conversation-derived field
    /// redacted. The user's own profile instructions and persona stay as
    /// written.
    mutating func redact(_ r: AnalysisRequest) -> AnalysisRequest {
        if r.usesReviewedFacts && r.reviewedFactContext == nil {
            return redact(r.preparingReviewedFacts())
        }
        // Stable code is redacted first so a changing conversation cannot
        // renumber its placeholders and accidentally change the cached prefix.
        // Ordinary document request ordering stays unchanged.
        let sourceFirst = r.usesRepository ? r.references.map {
            KBReference(documentName: $0.documentName, note: $0.note, text: redact($0.text),
                repositoryCitation: $0.repositoryCitation, repositoryContextRole: $0.repositoryContextRole)
        } : nil
        var copy = AnalysisRequest(
            transcript: redact(r.transcript),
            currentQuestion: r.currentQuestion.map { redact($0) },
            knownInsightTitles: r.knownInsightTitles.map { redact($0) },
            references: sourceFirst ?? r.references.map { KBReference(documentName: $0.documentName, note: $0.note,
                                                       text: redact($0.text), repositoryCitation: $0.repositoryCitation,
                                                       repositoryContextRole: $0.repositoryContextRole) },
            instructions: r.instructions,
            callBrief: redact(r.callBrief),
            allowGeneralKnowledge: r.allowGeneralKnowledge,
            knownDocumentNames: r.knownDocumentNames,
            persona: r.persona,
            counterpart: r.counterpart,
            kinds: r.kinds,
            gauges: r.gauges)
        copy.calendarContext = redact(r.calendarContext)
        copy.previousCallContext = redact(r.previousCallContext)
        copy.previousCallIsPrivate = r.previousCallIsPrivate
        copy.forceLocal = r.forceLocal
        copy.reviewedCatalog = r.reviewedCatalog
        copy.answerTrace = r.answerTrace
        copy.repositoryRevision = r.repositoryRevision
        copy.repositoryRuntimeScopeID = r.repositoryRuntimeScopeID
        copy.reviewedQuestionKey = r.reviewedQuestionKey ?? r.currentQuestion
        copy.reviewedFactContext = r.reviewedFactContext?.redacting { redact($0) }
        if let catalog = r.reviewedCatalog, catalog.mode == .wholeReply {
            let candidates = catalog.candidates(question: r.reviewedQuestionKey ?? r.currentQuestion ?? "",
                referenceNames: Set(r.references.map(\.documentName)))
            copy.reviewedSelectionEntries = catalog.selectionEntries(for: candidates).map { entry in
                ReviewedAnswerCatalog.SelectionEntry(id: entry.id, reply: redact(entry.reply),
                    applicability: redact(entry.applicability),
                    excludedScopes: entry.excludedScopes.map { redact($0) },
                    scopeKey: redact(entry.scopeKey), scopeCategory: entry.scopeCategory,
                    sourceAuthority: entry.sourceAuthority, supportedForms: entry.supportedForms)
            }
        }
        return copy
    }

    /// Canonical evidence comes from the original request, not placeholder
    /// substitution. Different originals can redact to the same bytes.
    static func canonicalEvidence(_ selected: [KBReference], indices selectedIndices: [Int],
                                  original: [KBReference], redacted: [KBReference])
        -> (references: [KBReference], indices: [Int])? {
        guard original.count == redacted.count, selected.count == selectedIndices.count else { return nil }
        func same(_ a: KBReference, _ b: KBReference) -> Bool {
            a.documentName == b.documentName && a.note == b.note && a.text == b.text
                && a.repositoryCitation == b.repositoryCitation
                && a.repositoryContextRole == b.repositoryContextRole
        }
        var restored: [KBReference] = []
        var indices: [Int] = []
        for (reference, index) in zip(selected, selectedIndices) {
            let matches = redacted.indices.filter { same(redacted[$0], reference) }
            guard redacted.indices.contains(index), matches.contains(index),
                  matches.allSatisfy({ same(original[$0], original[index]) }),
                  original[index].documentName == reference.documentName,
                  original[index].note == reference.note else { return nil }
            restored.append(original[index])
            indices.append(index)
        }
        return (restored, indices)
    }

    func restore(_ r: AnalysisResult, originalReferences: [KBReference] = [],
                 redactedReferences: [KBReference] = [],
                 requireStrictEvidence: Bool = false) -> AnalysisResult {
        AnalysisResult(
            insights: r.insights.map { d in
                var restored = InsightDraft(kindKey: d.kindKey, title: restore(d.title), detail: restore(d.detail),
                             source: d.source, reply: d.reply.map { restore($0) },
                             supersedes: d.supersedes.map { restore($0) },
                             evidenceQuote: d.evidenceQuote.map { restore($0) },
                             answerKey: d.answerKey.map { restore($0) },
                             evidenceSources: d.evidenceSources, evidenceReferences: d.evidenceReferences,
                             evidenceReferenceIndices: d.evidenceReferenceIndices,
                             evidenceFactCitations: d.evidenceFactCitations,
                             repositoryCitations: d.repositoryCitations)
                func rejected() -> InsightDraft {
                    ClaudeAnalysisProvider.applyingEvidenceReview(restored, approved: false)
                }
                if requireStrictEvidence && d.source != nil {
                    guard let refs = d.evidenceReferences, !refs.isEmpty else { return rejected() }
                }
                if let selected = d.evidenceReferences, !selected.isEmpty {
                    guard let selectedIndices = d.evidenceReferenceIndices,
                          let evidence = Self.canonicalEvidence(selected, indices: selectedIndices,
                        original: originalReferences, redacted: redactedReferences) else { return rejected() }
                    var sources: [String] = []
                    for ref in evidence.references where !sources.contains(ref.documentName) {
                        sources.append(ref.documentName)
                    }
                    guard d.evidenceSources == sources, d.source == sources.joined(separator: "; ")
                        else { return rejected() }
                    // Canonical literals such as [EMAIL_1] must remain byte-exact.
                    restored = InsightDraft(kindKey: restored.kindKey, title: restored.title,
                        detail: zip(evidence.indices, evidence.references).map {
                            "[p\($0.0)] \($0.1.repositoryCitation?.label ?? $0.1.documentName)\n\($0.1.text)"
                        }.joined(separator: "\n\n"), source: d.source, reply: restored.reply,
                        supersedes: restored.supersedes,
                        evidenceQuote: evidence.references.map(\.text).joined(separator: "\n\n"),
                        answerKey: restored.answerKey, evidenceSources: d.evidenceSources,
                        evidenceReferences: evidence.references, evidenceReferenceIndices: evidence.indices,
                        evidenceFactCitations: d.evidenceFactCitations,
                        repositoryCitations: evidence.references.contains { $0.repositoryCitation != nil }
                            ? evidence.references.compactMap(\.repositoryCitation) : nil)
                }
                return restored
            },
            sentiment: r.sentiment,
            read: r.read.map { restore($0) },
            coach: r.coach.map { restore($0) },
            resolved: r.resolved.map { restore($0) })
    }
}
