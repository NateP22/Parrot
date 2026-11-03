import Foundation
import SwiftData

extension ProfileTest {
    /// Isolated disk-store round trip, not native UI or old-schema migration proof.
    @MainActor
    static func testReviewedFactPersistence() {
        typealias A = ClaudeAnalysisProvider
        typealias Citation = ReviewedAnswerCatalog.FactCitation
        let citation = Citation(factID: "f-fictional", factDigest: String(repeating: "a", count: 64),
            sourceID: "s-fictional", sourceSHA256: String(repeating: "b", count: 64),
            sourceRevision: "fictional-r1", documentedProductVersion: "4.2",
            authority: .productHelp, startUTF8: 7, endUTF8: 81)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-fact-persistence-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
            let config = ModelConfiguration("Fact provenance test", schema: schema,
                url: folder.appendingPathComponent("facts.store"), cloudKitDatabase: .none)
            try autoreleasepool {
                let container = try ModelContainer(for: schema, configurations: [config])
                let context = ModelContext(container)
                context.insert(CallInsight(from: Insight(kindKey: "suggestion", title: "Fact test",
                    detail: "Exact local quote with UNREVIEWED_NEIGHBOR.", callTime: 12,
                    source: "Fictional Atlas", reply: "In Atlas 4.2, choose the separate line.",
                    evidenceFactCitations: [citation])))
                context.insert(CallInsight(from: Insight(kindKey: "suggestion", title: "Legacy test",
                    detail: "Older card detail.", callTime: 3, source: nil)))
                try context.save()
            }
            try autoreleasepool {
                let reopened = try ModelContainer(for: schema, configurations: [config])
                let rows = try ModelContext(reopened).fetch(FetchDescriptor<CallInsight>())
                let fact = rows.first { $0.title == "Fact test" }
                let legacy = rows.first { $0.title == "Legacy test" }
                check("facts: two rows reopen from disk", rows.count == 2)
                check("facts: source identities and byte ranges reopen exactly", fact?.evidenceFactCitations == [citation])
                check("facts: citation quote remains locally available", fact?.detail.contains("UNREVIEWED_NEIGHBOR") == true)
                check("facts: legacy optional provenance stays nil", legacy != nil && legacy?.evidenceFactCitationsData == nil)
            }
            let receipt = A.reportInsightReceipt(kind: "suggestion", title: "Fact test",
                source: "Fictional Atlas", reply: "In Atlas 4.2, choose the separate line.",
                callTime: 12, cardDetail: "UNREVIEWED_NEIGHBOR", factCitations: [citation])
            let record = try JSONSerialization.jsonObject(with: Data(receipt.utf8)) as! [String: Any]
            check("facts: report withholds raw source quote", record["card_detail"] == nil && !receipt.contains("UNREVIEWED_NEIGHBOR"))
            check("facts: report identifies suggestion as unconfirmed", (record["authorship"] as? String)?.contains("not a spoken or confirmed outcome") == true)
            check("facts: report does not export internal source identities", !receipt.contains(citation.factID)
                && !receipt.contains(citation.sourceSHA256) && record["source_reviewed_fact_count"] as? Int == 1)
            let malformed = CallInsight(from: Insight(kindKey: "suggestion", title: "Malformed", detail: "UNREVIEWED_NEIGHBOR", callTime: 0, source: nil))
            malformed.evidenceFactCitationsData = Data("invalid JSON".utf8)
            let guarded = A.reportInsightReceipt(kind: malformed.kindRaw, title: malformed.title,
                source: malformed.source, reply: malformed.reply, cardDetail: malformed.detail,
                factCitations: malformed.evidenceFactCitationsData == nil ? nil : (malformed.evidenceFactCitations ?? []))
            check("facts: malformed stored metadata never releases raw quote", !guarded.contains("UNREVIEWED_NEIGHBOR"))
            let old = A.reportInsightReceipt(kind: "suggestion", title: "Legacy", source: nil,
                reply: nil, cardDetail: "Legacy detail")
            check("facts: legacy report behavior preserved", old.contains("Legacy detail"))
        } catch {
            check("facts: disk persistence and report checks: \(error)", false)
        }
    }
}
