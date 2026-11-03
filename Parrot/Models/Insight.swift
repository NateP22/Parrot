import Foundation
import SwiftData

/// A single piece of live call intelligence produced by the CallAnalysisEngine.
struct Insight: Identifiable, Equatable {
    /// Reserved kind for the Jev fast path's "From your docs" excerpt card.
    /// Never a profile kind; filtered out of Haiku's known list, the dedup
    /// set, and persistence. The card is the bridge until Haiku's card lands.
    static let docExcerptKind = "doc_excerpt"

    let id = UUID()
    /// Stable kind key from the active profile (e.g. "suggestion", "objection",
    /// "reflection"). Styling is resolved from this key, never hardcoded.
    let kindKey: String
    let title: String
    let detail: String
    let callTime: TimeInterval
    let source: String?
    /// For unresolved flags: one short line the user could say to address it
    /// (KB-grounded when the documents cover it, else general knowledge).
    var reply: String? = nil
    /// App-resolved fact provenance; never supplied by model JSON.
    var evidenceFactCitations: [ReviewedAnswerCatalog.FactCitation]? = nil
    var repositoryCitations: [RepositoryCitation]? = nil
    let createdAt = Date()
    var isHandled = false

    var style: KindStyle { KindResolver.fallbackStyle(forKey: kindKey) }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@Model
final class CallInsight {
    var id: UUID
    var meeting: Meeting?
    var kindRaw: String
    var title: String
    var detail: String
    var callTime: TimeInterval
    var source: String?
    /// Suggested line to address an unresolved flag (defaulted → old rows migrate).
    var reply: String? = nil
    /// Optional for legacy rows. Exact source identities survive save/reopen.
    var evidenceFactCitationsData: Data? = nil
    var repositoryCitationsData: Data? = nil
    var isHandled: Bool

    init(from insight: Insight) {
        self.id = insight.id
        self.kindRaw = insight.kindKey
        self.title = insight.title
        self.detail = insight.detail
        self.callTime = insight.callTime
        self.source = insight.source
        self.reply = insight.reply
        self.evidenceFactCitationsData = insight.evidenceFactCitations.map { (try? JSONEncoder().encode($0)) ?? Data() }
        self.repositoryCitationsData = insight.repositoryCitations.flatMap { try? JSONEncoder().encode($0) }
        self.isHandled = insight.isHandled
    }

    var evidenceFactCitations: [ReviewedAnswerCatalog.FactCitation]? {
        guard let data = evidenceFactCitationsData else { return nil }
        return try? JSONDecoder().decode([ReviewedAnswerCatalog.FactCitation].self, from: data)
    }

    var repositoryCitations: [RepositoryCitation]? {
        guard let data = repositoryCitationsData else { return nil }
        return try? JSONDecoder().decode([RepositoryCitation].self, from: data)
    }

    var style: KindStyle { KindResolver.fallbackStyle(forKey: kindRaw) }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
