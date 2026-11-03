#!/usr/bin/env python3
"""Compile actual fact admission/request/parser/privacy/store code with fictional data.

The copied catalog uses a synthetic test trust root only in a temporary directory.
Production trust is never changed. No network, credentials, client corpus or gold
answers are used. These checks do not establish model judgment or native acceptance.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
provider = (root / "Parrot/Services/AnalysisProvider.swift").read_text()


def block(source, start, indent="    "):
    i = source.index(start)
    j = source.index("\n" + indent + "}", i) + len("\n" + indent + "}")
    return source[i:j]


def structure(name):
    return block(provider, "struct " + name + " {", "")


def literal(name):
    start = provider.index("    static let " + name + ' = """')
    end = provider.index('\n        """', start) + len('\n        """')
    return provider[start:end]


subject = """
import Foundation
import CryptoKit
struct ProfileKind { let key: String; var isPinned = false }
struct SentimentGauge {}
struct AnswerTraceLink {}
enum FixtureTrust {
    // Deliberately public, synthetic test material. Never a production credential.
    static let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map { UInt8($0) }))
    static var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
}
"""
subject += "\n" + "\n".join(structure(n) for n in ("InsightDraft", "AnalysisRequest", "AnalysisResult"))
subject += "\nenum ClaudeAnalysisProvider {\n"
for name in ("model", "directAnswerKinds", "checkFirstMessage"):
    subject += next(line for line in provider.splitlines() if "static let " + name in line) + "\n"
for name in ("strictAnswerSystemPrompt", "reviewedFactRule", "evidenceReviewPrompt"):
    subject += literal(name) + "\n"
for name in ("strictAnswerKind", "evidenceItems", "strictPrompt", "strictAnswerContent",
             "parseStrictAnswer", "isConciseSpokenReply", "isActionableAbstention",
             "evidenceReviewBody", "evidenceReviewPassed", "applyingEvidenceReview",
             "applyingReviewedEvidence", "reportInsightReceipt"):
    subject += block(provider, "    static func " + name + "(") + "\n"
subject += block(provider, "    private static func checkFirstDraft(") + "\n"
subject += block(provider, "    private struct MessagesResponse:") + "\n}\n"

main = r'''
import Foundation
import CryptoKit
typealias C = ReviewedAnswerCatalog
typealias A = ClaudeAnalysisProvider
var checks = 0
var failures = 0
func check(_ name: String, _ pass: Bool) {
    checks += 1
    if !pass { failures += 1; print("FAIL " + name) }
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); check(name, false) } catch { check(name, true) }
}
func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}
func envelope(_ payload: [String: Any], format: String = "parrot-reviewed-facts-signed-v1") throws -> Data {
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let signature = try FixtureTrust.key.signature(for: bytes)
    return try JSONSerialization.data(withJSONObject: ["format": format,
        "payload": bytes.base64EncodedString(), "signature": signature.base64EncodedString()])
}
func response(_ value: [String: Any], stop: String = "end_turn") throws -> Data {
    let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "stop_reason": stop])
}
func request(_ snapshot: C.Snapshot, question: String, refs: [KBReference] = []) -> AnalysisRequest {
    AnalysisRequest(transcript: "Them: " + question, currentQuestion: question, knownInsightTitles: [],
        references: refs, instructions: "Use plain words.", callBrief: "Fictional control.",
        allowGeneralKnowledge: false, knownDocumentNames: ["Fictional Atlas.md"], persona: "",
        counterpart: "the client", kinds: [ProfileKind(key: "suggestion")], gauges: [],
        reviewedCatalog: snapshot)
}
func fallback(_ draft: InsightDraft) -> Bool {
    draft.reply == nil && draft.source == nil && draft.evidenceReferences == nil
        && draft.evidenceFactCitations == nil && draft.detail == A.checkFirstMessage
}
func verdict(answers: Bool = true, conditions: Bool = true, ids: [String] = ["p0"]) throws -> Data {
    try response(["supported": true, "answers_question": answers, "preserves_conditions": conditions,
        "clear_and_sayable": true, "missing_conditions": conditions ? [] : ["separate-line switch"],
        "unclear_terms": [], "evidence_ids": ids])
}
do {
    let sourceText = "é🦜 Atlas 4.2 supports a separate footer line when Separate Line is enabled. Atlas 4.2 requires selecting the existing footer frame and choosing Reset to refresh it. UNREVIEWED_NEIGHBOR: fictional secret workflow. Contact atlas@fictional.example."
    let hash = C.sha256(Data(sourceText.utf8))
    func source(_ id: String) -> C.Source {
        C.Source(id: id, name: "Fictional Atlas.md", provider: "Fictional vendor",
            authority: .productHelp, revision: "fictional-r1", productVersion: "4.2",
            urls: ["https://fictional.invalid/atlas"], sha256: hash, text: sourceText)
    }
    let s = source("s-" + source("").identityDigest)
    let evidence = C.Evidence(sourceID: s.id, startUTF8: 0, endUTF8: sourceText.utf8.count, quote: sourceText)
    let draftFact = C.Fact(id: "", claim: "Atlas supports a separate footer line.",
        scopeKey: "atlas.footer", category: .productControl, applicability: "Atlas footer placement.",
        conditions: ["Separate Line must be enabled."], excludedScopes: ["Does not describe cloud publishing."],
        requiredClientContext: [], evidence: evidence, sourceSHA256: hash, sourceRevision: s.revision,
        documentedProductVersion: s.productVersion, authority: s.authority,
        review: C.Review(verdict: "PASS_SOURCE_FACT", reviewer: "fictional source reviewer", reviewedAt: "2026-01-01", digest: ""))
    var fact = try object(draftFact)
    fact["id"] = "f-" + draftFact.contentDigest.prefix(24)
    var review = fact["review"] as! [String: Any]; review["digest"] = draftFact.contentDigest; fact["review"] = review
    let payload: [String: Any] = ["format": C.factFileFormat, "mode": "reviewedFacts",
        "sources": [try object(s)], "answers": [], "facts": [fact]]
    let signed = try envelope(payload)
    let catalog = try C.decode(signed)
    check("signed reviewed-fact payload decodes", catalog.effectiveMode == .reviewedFacts && catalog.facts?.count == 1)
    let doc = KBDocument(name: s.name, chunkCount: 1, addedAt: Date(), contentSHA256: hash)
    let snap = catalog.admitted(documents: [doc], folders: [], profileID: nil)
    check("current exact imported source admits fact", snap.mode == .reviewedFacts && snap.facts.count == 1 && snap.answers.isEmpty)
    let factID = fact["id"] as! String
    func alteredFact(_ name: String, _ change: (inout [String: Any]) -> Void) throws {
        var changed = fact; change(&changed)
        var p = payload; p["facts"] = [changed]
        rejects(name) { _ = try C.decode(envelope(p)) }
    }
    try alteredFact("changed claim invalidates review digest") { $0["claim"] = "Atlas always enables the footer." }
    try alteredFact("changed condition invalidates review digest") { $0["conditions"] = [] }
    try alteredFact("wrong source hash rejected") { $0["sourceSHA256"] = String(repeating: "0", count: 64) }
    try alteredFact("wrong source revision rejected") { $0["sourceRevision"] = "fictional-r2" }
    try alteredFact("wrong documented version rejected") { $0["documentedProductVersion"] = "4.2.1" }
    try alteredFact("authority mismatch rejected") { $0["authority"] = "vendorReference" }
    try alteredFact("unverified client state rejected") { $0["requiredClientContext"] = ["Client enabled the switch."] }
    try alteredFact("old whole-reply review cannot authorize fact") {
        var r = $0["review"] as! [String: Any]; r["verdict"] = "PASS_SOURCE_ONLY"; $0["review"] = r
    }
    for field in ["startUTF8", "endUTF8", "quote", "sourceID"] {
        try alteredFact("tampered UTF8 evidence " + field) {
            var e = $0["evidence"] as! [String: Any]
            if field == "startUTF8" { e[field] = 1 }
            else if field == "endUTF8" { e[field] = 9999 }
            else if field == "quote" { e[field] = "Edited quote." }
            else { e[field] = "unknown" }
            $0["evidence"] = e
        }
    }
    var duplicate = payload; duplicate["facts"] = [fact, fact]
    rejects("duplicate fact identity rejected") { _ = try C.decode(envelope(duplicate)) }
    var noMode = payload; noMode.removeValue(forKey: "mode")
    rejects("fact mode must be explicit") { _ = try C.decode(envelope(noMode)) }
    var unknown = payload; unknown["mode"] = "unreviewed"
    rejects("unknown mode cannot degrade to raw generation") { _ = try C.decode(envelope(unknown)) }
    rejects("outer and inner formats must agree") { _ = try C.decode(envelope(payload, format: "parrot-reviewed-answers-signed-v2")) }
    var invalidSig = try JSONSerialization.jsonObject(with: signed) as! [String: Any]
    invalidSig["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
    rejects("invalid signature rejected") { _ = try C.decode(JSONSerialization.data(withJSONObject: invalidSig)) }
    var changedDoc = doc; changedDoc.contentSHA256 = String(repeating: "0", count: 64)
    var unknownDoc = doc; unknownDoc.contentSHA256 = nil
    var offDoc = doc; offDoc.scope = .off
    var scopedDoc = doc; scopedDoc.scope = .only([UUID()])
    for (name, docs, profile) in [
        ("missing", [KBDocument](), Optional<UUID>.none), ("changed", [changedDoc], nil),
        ("unknown", [unknownDoc], nil), ("duplicate", [doc, doc], nil),
        ("disabled", [offDoc], nil), ("other profile", [scopedDoc], UUID()),
    ] {
        let rejected = catalog.admitted(documents: docs, folders: [], profileID: profile)
        check("source admission refuses " + name, rejected.facts.isEmpty && !rejected.admissionIssues.isEmpty)
        check("source change invalidates snapshot " + name, rejected.revisionToken != snap.revisionToken)
    }
    var folder = KBFolder(name: "Fictional disabled", scope: .off)
    var folderDoc = doc; folderDoc.folderID = folder.id
    check("folder-off scope rejects fact", catalog.admitted(documents: [folderDoc], folders: [folder], profileID: nil).facts.isEmpty)
    folder.scope = .all
    check("folder-all admits unchanged fact", catalog.admitted(documents: [folderDoc], folders: [folder], profileID: nil).facts.count == 1)

    let question = "How do I put the Atlas footer on a separate line?"
    let req = request(snap, question: question).preparingReviewedFacts()
    check("generic overlap retrieves reviewed claim", req.reviewedFactContext?.citations.first?.factID == factID)
    check("local citation retains original UTF8 bytes", req.references.first?.text == sourceText)
    let followup = request(snap, question: "How do I do that?", refs: req.references).preparingReviewedFacts()
    check("generic followup may nominate an exact retrieved fact quote", followup.reviewedFactContext?.isEmpty == false)
    check("unresolved followup without retrieved evidence stays empty", request(snap, question: "How do I do that?").preparingReviewedFacts().reviewedFactContext?.isEmpty == true)
    let irrelevant = request(snap, question: "What is the weather tomorrow?",
        refs: [KBReference(documentName: s.name, note: nil, text: "Unrelated weather passage.")]).preparingReviewedFacts()
    check("document name alone cannot admit irrelevant fact", irrelevant.reviewedFactContext?.isEmpty == true)
    let wrongVersion = request(snap, question: "How does Atlas 4.2.1 footer placement work?").preparingReviewedFacts()
    check("explicit other version excluded", wrongVersion.reviewedFactContext?.isEmpty == true)
    check("exact version accepted", C.containsDocumentedVersion("4.2", in: "In Atlas 4.2, enable it."))
    check("optional v version accepted", C.containsDocumentedVersion("4.2", in: "In Atlas v4.2, enable it."))
    for v in ["4.2.1", "14.2", "4.20", "4.2-beta", "4.2+build", "x4.2"] {
        check("version boundary refuses " + v, !C.containsDocumentedVersion("4.2", in: "In Atlas " + v + ", enable it."))
    }
    let gen = try JSONSerialization.jsonObject(with: Data(A.strictAnswerContent(req).utf8)) as! [String: Any]
    let passages = gen["passages"] as! [[String: Any]]
    let generationJSON = try JSONSerialization.data(withJSONObject: passages, options: [.sortedKeys])
    let generationText = String(decoding: generationJSON, as: UTF8.self)
    check("generator gets claim, not neighboring source text", generationText.contains(draftFact.claim)
        && !generationText.contains("UNREVIEWED_NEIGHBOR") && !generationText.contains("atlas@fictional.example"))
    check("generator keeps condition and scope metadata", generationText.contains("Separate Line must be enabled.")
        && generationText.contains("4.2") && generationText.contains("Does not describe cloud publishing."))
    let reply = "In Atlas 4.2, enable Separate Line to put the footer on its own line."
    let answer = A.parseStrictAnswer(from: try response(["reply": reply, "evidence_ids": ["p0"]]), request: req).insights[0]
    check("app resolves exact citation identity", answer.evidenceFactCitations?.first?.factID == factID
        && answer.evidenceFactCitations?.first?.sourceSHA256 == hash
        && answer.evidenceFactCitations?.first?.endUTF8 == sourceText.utf8.count)
    check("model cannot replace citation with invented metadata", A.parseStrictAnswer(from: try response([
        "reply": reply, "evidence_ids": ["p0"], "factID": "model-invented"]), request: req).insights[0].evidenceFactCitations == answer.evidenceFactCitations)
    let reviewBody = try A.evidenceReviewBody(answer, question: question, references: req.references,
        recentConversation: req.transcript, admittedEvidence: A.evidenceItems(req))
    let messages = reviewBody["messages"] as! [[String: String]]
    let reviewContent = try JSONSerialization.jsonObject(with: Data(messages[0]["content"]!.utf8)) as! [String: Any]
    let reviewEvidence = try JSONSerialization.data(withJSONObject: reviewContent["available_evidence"]!, options: [.sortedKeys])
    check("generation and reviewer receive identical reviewed facts", reviewEvidence == generationJSON)
    check("reviewer receives no source quote", !messages[0]["content"]!.contains("UNREVIEWED_NEIGHBOR"))
    check("fact prompt describes reviewed claims and completeness", A.strictPrompt(req).contains("source-reviewed facts")
        && A.strictPrompt(req).contains("cover every requested part"))
    for (label, value, stop) in [
        ("missing version", "Enable Separate Line to put the footer on its own line.", "end_turn"),
        ("wrong version", "In Atlas 4.2.1, enable Separate Line.", "end_turn"),
        ("overlong", "In Atlas 4.2, " + String(repeating: "word ", count: 35) + ".", "end_turn"),
        ("truncated", reply, "max_tokens"),
    ] {
        let refused = A.parseStrictAnswer(from: try response(["reply": value, "evidence_ids": ["p0"]], stop: stop), request: req).insights[0]
        check("parser refuses " + label, fallback(refused))
    }
    check("unknown passage rejected", fallback(A.parseStrictAnswer(from: try response(["reply": reply, "evidence_ids": ["p9"]]), request: req).insights[0]))
    var stale = req; stale.currentQuestion = "What happens to cloud publishing?"
    check("changed displayed question invalidates context", stale.preparingReviewedFacts().reviewedFactContext?.isEmpty == true)
    check("stale context never raw-falls-back in payload", A.evidenceItems(stale).isEmpty)
    check("stale context never yields cited answer", fallback(A.parseStrictAnswer(from: try response(["reply": reply, "evidence_ids": ["p0"]]), request: stale).insights[0]))
    var keyStale = req; keyStale.reviewedQuestionKey = "Another original question"
    check("changed original question invalidates context", keyStale.preparingReviewedFacts().reviewedFactContext?.isEmpty == true)
    var refsStale = req; refsStale.references = [KBReference(documentName: s.name, note: nil, text: "Edited bytes")]
    check("changed source reference invalidates context", A.evidenceItems(refsStale).isEmpty)
    var scopeStale = req; scopeStale.reviewedCatalog = catalog.admitted(documents: [offDoc], folders: [], profileID: nil)
    check("changed admission revision invalidates context", scopeStale.preparingReviewedFacts().reviewedFactContext?.isEmpty == true)

    let approved = A.applyingReviewedEvidence(try verdict(), to: answer, request: req)
    check("positive mock verdict preserves exact candidate and citation", approved?.reply == reply && approved?.evidenceFactCitations == answer.evidenceFactCitations)
    check("partial mock verdict cannot approve compound answer", A.applyingReviewedEvidence(try verdict(answers: false), to: answer, request: req) == nil)
    check("missing-condition mock verdict cannot approve", A.applyingReviewedEvidence(try verdict(conditions: false), to: answer, request: req) == nil)
    check("reviewer unknown ID cannot invent citation", A.applyingReviewedEvidence(try verdict(ids: ["p5"]), to: answer, request: req) == nil)
    let rejected = A.applyingEvidenceReview(answer, approved: false)
    check("review failure drops source and citations but keeps question", fallback(rejected) && rejected.answerKey == question)

    var secondFact = fact
    secondFact["claim"] = "Atlas requires Reset to refresh existing footer frames."
    secondFact["scopeKey"] = "atlas.refresh"
    secondFact["conditions"] = ["Select the existing footer frame before Reset."]
    let secondDecoded = try JSONDecoder().decode(C.Fact.self, from: JSONSerialization.data(withJSONObject: secondFact))
    let secondID = "f-" + secondDecoded.contentDigest.prefix(24)
    secondFact["id"] = secondID
    var secondReview = secondFact["review"] as! [String: Any]
    secondReview["digest"] = secondDecoded.contentDigest; secondFact["review"] = secondReview
    var compoundPayload = payload; compoundPayload["facts"] = [fact, secondFact]
    let compoundCatalog = try C.decode(envelope(compoundPayload))
    let compoundSnapshot = compoundCatalog.admitted(documents: [doc], folders: [], profileID: nil)
    let compoundQuestion = "How do I put the footer on a separate line and refresh existing frames?"
    let compound = request(compoundSnapshot, question: compoundQuestion).preparingReviewedFacts()
    let compoundCitations = compound.reviewedFactContext!.citations
    check("distinct facts can be nominated without whole-reply aliases", compoundCitations.count == 2)
    let pForFirst = "p" + String(compoundCitations.firstIndex { $0.factID == factID }!)
    let pForSecond = "p" + String(compoundCitations.firstIndex { $0.factID == secondID }!)
    let combinedReply = "In Atlas 4.2, enable Separate Line; select the existing footer frame and choose Reset to refresh it."
    let combined = A.parseStrictAnswer(from: try response(["reply": combinedReply,
        "evidence_ids": [pForSecond, pForFirst]]), request: compound).insights[0]
    check("citation order follows app-resolved selected IDs", combined.evidenceFactCitations?.map(\.factID) == [secondID, factID])
    let secondOnly = A.parseStrictAnswer(from: try response(["reply": "In Atlas 4.2, select the existing footer frame and choose Reset.",
        "evidence_ids": [pForSecond]]), request: compound).insights[0]
    check("second-only selection resolves its own exact fact", secondOnly.evidenceFactCitations?.map(\.factID) == [secondID])
    check("negative completeness verdict refuses partial compound", A.applyingReviewedEvidence(
        try verdict(answers: false, ids: [pForSecond]), to: secondOnly, request: compound) == nil)
    // This records the semantic trust boundary, not a semantic pass: a falsely
    // positive model verdict is not detected by a deterministic ID parser.
    check("positive-shaped verdict alone cannot prove semantic completeness", A.applyingReviewedEvidence(
        try verdict(ids: [pForSecond]), to: secondOnly, request: compound) != nil)

    var redactor = Redactor(hideNames: false)
    let personalQuestion = "How do I put the Atlas footer for atlas@fictional.example on a separate line?"
    let original = request(snap, question: personalQuestion).preparingReviewedFacts()
    let redacted = redactor.redact(original)
    check("privacy binds redacted displayed question to original selection", redacted.reviewedFactContext?.matches(
        question: redacted.currentQuestion ?? "", selectionQuestion: personalQuestion, references: redacted.references) == true)
    check("privacy redacts canonical quote projection only", !redacted.references[0].text.contains("atlas@fictional.example")
        && original.references[0].text == sourceText)
    check("privacy preserves app-owned citation identities", redacted.reviewedFactContext?.citations == original.reviewedFactContext?.citations)
    let privateDraft = A.parseStrictAnswer(from: try response(["reply": reply, "evidence_ids": ["p0"]]), request: redacted).insights[0]
    let restored = redactor.restore(AnalysisResult(insights: [privateDraft], sentiment: [:], read: nil, coach: nil, resolved: []),
        originalReferences: original.references, redactedReferences: redacted.references, requireStrictEvidence: true).insights[0]
    check("canonical quote is byte exact after privacy roundtrip", restored.evidenceQuote == sourceText)
    check("fact provenance survives privacy roundtrip", restored.evidenceFactCitations == original.reviewedFactContext?.citations)
    let citationBytes = try JSONEncoder().encode(restored.evidenceFactCitations!)
    check("citation metadata Codable roundtrip", try JSONDecoder().decode([C.FactCitation].self, from: citationBytes) == restored.evidenceFactCitations!)
    let receipt = A.reportInsightReceipt(kind: answer.kindKey, title: answer.title, source: answer.source,
        reply: answer.reply, cardDetail: answer.detail, factCitations: answer.evidenceFactCitations)
    check("report does not export raw quote or internal identifiers", !receipt.contains("UNREVIEWED_NEIGHBOR")
        && !receipt.contains(hash) && !receipt.contains(factID))
    let emptyReceipt = A.reportInsightReceipt(kind: "suggestion", title: "Check", source: nil,
        reply: nil, cardDetail: sourceText, factCitations: [])
    check("empty nonnil fact metadata still withholds quote", !emptyReceipt.contains("UNREVIEWED_NEIGHBOR"))

    // Whole-reply mode is signed separately and never silently promoted to facts.
    let scope = ReviewedQuestionScope(key: "atlas.footer", category: .productControl,
        requiredPhrases: [["footer"]], forbiddenPhrases: [])
    let oldAnswer = C.Answer(id: "", kind: .instruction, title: "Footer placement", reply: reply,
        applicability: "Atlas footer placement.", excludedScopes: [], searchTerms: ["footer"],
        requiredClientContext: [], scope: scope, supportedForms: [.procedure], evidence: [evidence],
        review: C.Review(verdict: "PASS_SOURCE_ONLY", reviewer: "fictional", reviewedAt: "2026-01-01", digest: ""))
    var old = try object(oldAnswer); old["id"] = "a-" + oldAnswer.contentDigest.prefix(24)
    var oldReview = old["review"] as! [String: Any]; oldReview["digest"] = oldAnswer.contentDigest; old["review"] = oldReview
    let oldPayload: [String: Any] = ["format": C.fileFormat, "sources": [try object(s)], "answers": [old]]
    let legacyData = try envelope(oldPayload, format: "parrot-reviewed-answers-signed-v2")
    let legacy = try C.decode(legacyData)
    check("legacy v2 payload without new fields still decodes", legacy.effectiveMode == .wholeReply && legacy.facts == nil && legacy.answers.count == 1)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-fact-store-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = ReviewedAnswerStore(url: temp.appendingPathComponent("reviewed.json"))
    check("unconfigured store remains explicit", !store.isConfigured)
    rejects("invalid import fails closed") { _ = try store.install(Data("invalid".utf8)) }
    check("invalid first import preserves required intent", store.isConfigured)
    rejects("missing required store cannot load raw fallback") { _ = try store.load() }
    _ = try store.install(signed)
    check("fact library survives store save/reopen", try ReviewedAnswerStore(url: store.url).load()?.facts?.first?.id == factID)
    rejects("invalid replacement leaves working bytes intact") { _ = try store.install(Data("invalid".utf8)) }
    check("working library preserved after invalid replacement", try Data(contentsOf: store.url) == signed)
    _ = try store.install(legacyData)
    let backups = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("reviewed-answers-backup-") }
    let backupBytes = backups.count == 1 ? try Data(contentsOf: backups[0]) : Data()
    check("replacement creates exact rollback bytes", backups.count == 1 && backupBytes == signed)
    _ = try store.install(signed)
    check("explicit rollback revalidates and reads back", try Data(contentsOf: store.url) == signed)
    try Data("corrupt".utf8).write(to: store.url)
    rejects("corrupt saved library cannot enable raw fallback") { _ = try store.load() }
} catch {
    failures += 1; print("FAIL harness \(error)")
}
print("REVIEWED FACTS: \(checks) checks; \(failures) failures; actual source, synthetic trust root, inert verdicts; no model/native acceptance")
exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix="parrot-reviewed-facts-") as directory:
    temp = Path(directory)
    files = []
    for relative in ("Services/ReviewedAnswerCatalog.swift", "Services/ReviewedFacts.swift",
                     "Services/ReviewedQuestionScope.swift", "Models/KnowledgeBase.swift",
                     "Services/ReviewedAnswerStore.swift", "Services/Redactor.swift"):
        content = (root / "Parrot" / relative).read_text()
        if relative.endswith("ReviewedAnswerCatalog.swift"):
            production_line = next(line for line in content.splitlines() if "static let verificationKeyBase64 =" in line)
            content = content.replace(production_line, "    static let verificationKeyBase64 = FixtureTrust.publicKeyBase64", 1)
        path = temp / Path(relative).name
        path.write_text(content)
        files.append(str(path))
    (temp / "Subject.swift").write_text(subject)
    (temp / "main.swift").write_text(main)
    binary = temp / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(temp / "module-cache"),
                    *files, str(temp / "Subject.swift"), str(temp / "main.swift"), "-o", str(binary)],
                   check=True, timeout=180)
    raise SystemExit(subprocess.run([str(binary)], timeout=30).returncode)
