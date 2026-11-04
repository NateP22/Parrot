#!/usr/bin/env python3
"""Actual code-mode request builders, fictional data and inert transport only."""
from pathlib import Path
import argparse, platform, subprocess, tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work-root', type=Path)
args = parser.parse_args()

root = Path(__file__).resolve().parents[1]
source = (root / 'Parrot/Services/AnalysisProvider.swift').read_text()
engine = (root / 'Parrot/Services/CallAnalysisEngine.swift').read_text()
limit_line = next(line.strip() for line in engine.splitlines() if 'let referenceLimit = requestedRepositoryRevision' in line)
assert 'topK: referenceLimit, contextNeighbors: strict ? 1 : 0' in engine
assert 'limit: min(32, max(0, topK))' in (root / 'Parrot/Services/KnowledgeBaseService.swift').read_text()
def method(name):
    start = source.index(name)
    return source[start:source.index('\n    }', start) + len('\n    }')]
def literal(name):
    start = source.index('    static let ' + name + ' = """')
    return source[start:source.index('\n        """', start) + len('\n        """')]
subject = '''
import Foundation
struct RepositoryCitation { let commit: String; let path: String; let startLine: Int; let endLine: Int; var revision = "revision-a" }
struct KBReference { let documentName: String; let text: String; var repositoryCitation: RepositoryCitation? = nil; var note: String? = nil; var repositoryContextRole: String? = nil }
struct InsightDraft { let reply: String?; let source: String? }
struct AnalysisRequest {
 var transcript: String; var currentQuestion: String?; var references: [KBReference]
 var instructions = ""; var callBrief = ""; var reviewedModelEvidence: [[String: Any]]? = nil
 var usesReviewedFacts = false; var usesRepository = false; var repositoryRuntimeScopeID: String? = nil
}
final class Subject {
 static let model = "fictional-no-network"
 var bodies: [[String: Any]] = []
 func performRequest(body: [String: Any], apiKey: String, timeout: TimeInterval, retryTransient: Bool, repositoryContext: Bool = false) async throws -> Data {
  _ = try RepositoryPromptCache.encodedBody(body, required: repositoryContext)
  bodies.append(body); return Data()
 }
 static func applyingReviewedEvidence(_ data: Data, to draft: InsightDraft, request: AnalysisRequest) -> InsightDraft? { draft }
 func review(_ draft: InsightDraft, _ request: AnalysisRequest) async throws { _ = try await reviewAnswer(draft, request: request, apiKey: "fictional-unused") }
 func reviewResult(_ draft: InsightDraft, _ request: AnalysisRequest) async throws -> InsightDraft? { try await reviewAnswer(draft, request: request, apiKey: "fictional-unused") }
'''
subject += '\n'.join(method(n) for n in ['    static func evidenceItems(', '    static func strictAnswerContent(', '    static func strictAnswerMessages(', '    static func evidenceReviewBody(', '    private func reviewAnswer('])
subject += '\n static func actualEngineReferenceLimit(_ requestedRepositoryRevision: String?, strict: Bool) -> Int { ' + limit_line + '; return referenceLimit }\n'
subject += '\n' + '\n'.join(literal(n) for n in ['repositorySourceRule', 'reviewedFactRule', 'evidenceReviewPrompt']) + '\n}\n'
subject += (root / 'Parrot/Services/RepositoryPromptCache.swift').read_text()
main = r'''
import Foundation
var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) { checks += 1; if !value { failures += 1; print("FAIL " + name) } }
func blocks(_ messages: [[String: Any]]) -> [[String: Any]] { messages[0]["content"] as! [[String: Any]] }
func object(_ block: [String: Any]) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data((block["text"] as! String).utf8)) as! [String: Any] }
func bytes(_ block: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys]) }
func stableBytes(_ value: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: Array(value.dropLast()), options: [.sortedKeys]) }
func items(_ value: [[String: Any]], _ key: String) throws -> [[String:Any]] { try value.flatMap { try object($0)[key] as? [[String:Any]] ?? [] } }
func request(_ question: String, ui: String, doc: String) -> AnalysisRequest {
 let cite = RepositoryCitation(commit: String(repeating: "a", count: 40), path: "desktop/logic.js", startLine: 1, endLine: 80)
 var request = AnalysisRequest(transcript: "Them: " + question, currentQuestion: question, references: [
  .init(documentName: "logic.js", text: "Atlas.draw = function(v) { if (!v.ready) return false; return v; }; // [EMAIL_1]", repositoryCitation: cite, note: "Original whole module; conditional runtime unverified", repositoryContextRole: "module"),
  .init(documentName: "loader.js", text: "function boot() { $.evalFile(item); }", repositoryCitation: cite, note: "Declared loader only", repositoryContextRole: "loader"),
  .init(documentName: "ui.html", text: ui, repositoryCitation: cite, repositoryContextRole: "ui"),
  .init(documentName: "guide.md", text: doc)])
 request.usesRepository = true; request.repositoryRuntimeScopeID = "desktop"; return request
}
Task {
 do {
  let first = request("May I enable it?", ui: "<label>First panel</label>", doc: "First supporting guide.")
  let second = request("What if permission is missing?", ui: "<label>Other panel</label>", doc: "Other supporting guide.")
  let generationA = blocks(try Subject.strictAnswerMessages(first)), generationB = blocks(try Subject.strictAnswerMessages(second))
  check("generation source prefix stable across questions", try bytes(generationA[0]) == bytes(generationB[0]))
  check("first and last stable blocks have1h breakpoints, suffix never cached", generationA.dropLast().allSatisfy { ($0["cache_control"] as? [String:String]) == ["type":"ephemeral","ttl":"1h"] } && generationA.last!["cache_control"] == nil)
  let suffixA = try object(generationA.last!), suffixB = try object(generationB.last!)
  check("prefix excludes every changing question/history/UI/doc", !(generationA[0]["text"] as! String).contains(first.currentQuestion!) && !(generationA[0]["text"] as! String).contains("First panel") && !(generationA[0]["text"] as! String).contains("supporting guide"))
  check("generation preserves app-owned code passage IDs", try items(Array(generationA.dropLast()), "passages").map { $0["id"] as! String } == ["p0","p1"])
  check("varying evidence keeps original positions", (suffixA["passages"] as! [[String:Any]]).map { $0["id"] as! String } == ["p2","p3"])
  check("changing question and history remain suffix", suffixA["latest_question"] as? String == first.currentQuestion && suffixB["recent_conversation"] as? String == second.transcript)
  let subject = Subject(), draft = InsightDraft(reply: "Check readiness first.", source: "logic.js")
  try await subject.review(draft, first); try await subject.review(draft, second)
  let reviewA = blocks(subject.bodies[0]["messages"] as! [[String:Any]]), reviewB = blocks(subject.bodies[1]["messages"] as! [[String:Any]])
  check("review source prefix independently stable", try bytes(reviewA[0]) == bytes(reviewB[0]))
  check("review question/answer/history only suffix", try object(reviewA.last!)["question"] as? String == first.currentQuestion && object(reviewA.last!)["answer"] as? String == draft.reply)
  check("generation and review prefix modes not assumed shared", try bytes(reviewA[0]) != bytes(generationA[0]))
  check("review code IDs unchanged", try items(Array(reviewA.dropLast()), "available_evidence").map { $0["id"] as! String } == ["p0","p1"])
  var expanded = first
  for i in 0..<7 { expanded.references.append(.init(documentName: "helper\(i).js", text: "function helper\(i)(v){ if (!v.ready) return false; return v; }", repositoryCitation: first.references[0].repositoryCitation, repositoryContextRole: "related_declarations")) }
  let expandedBlocks = blocks(try Subject.strictAnswerMessages(expanded))
  let expandedIDs = try items(Array(expandedBlocks.dropLast()), "passages").map { $0["id"] as! String }
  check("more than6 code references retain original IDs in cached wire", expandedIDs == ["p0","p1","p4","p5","p6","p7","p8","p9","p10"])
  let expandedSubject = Subject(); try await expandedSubject.review(draft, expanded)
  let expandedReview = blocks(expandedSubject.bodies[0]["messages"] as! [[String:Any]])
  let expandedReviewIDs = try items(Array(expandedReview.dropLast()), "available_evidence").map { $0["id"] as! String }
  let expandedReviewSuffix = try object(expandedReview.last!)["available_evidence"] as! [[String:Any]]
  check("review preserves greater-than6 code IDs and suffix", expandedReviewIDs == expandedIDs && expandedReviewSuffix.count == 2)
  var thirtyTwo = first
  for i in 0..<29 { thirtyTwo.references.append(.init(documentName: "guard\(i).js", text: "function guard\(i)(v){return v.ready;}", repositoryCitation: first.references[0].repositoryCitation, repositoryContextRole: "related_declarations")) }
  let expected32 = ["p0","p1"] + (4..<33).map { "p\($0)" }
  // first has three code references, of which the UI stays in the suffix.
  let blocks32 = blocks(try Subject.strictAnswerMessages(thirtyTwo))
  check("32 code references accepted with stable original generation IDs", try items(Array(blocks32.dropLast()), "passages").map { $0["id"] as! String } == expected32)
  let review32 = Subject(); try await review32.review(draft, thirtyTwo)
  let review32blocks = blocks(review32.bodies[0]["messages"] as! [[String:Any]])
  check("32 code references accepted with same review IDs", try items(Array(review32blocks.dropLast()), "available_evidence").map { $0["id"] as! String } == expected32)
  var anotherQuestion = thirtyTwo; anotherQuestion.currentQuestion = second.currentQuestion; anotherQuestion.transcript = second.transcript
  check("32-code cached generation prefix stable across questions", try stableBytes(blocks32) == stableBytes(blocks(Subject.strictAnswerMessages(anotherQuestion))))
  let reviewAgain = Subject(); try await reviewAgain.review(draft, anotherQuestion)
  check("32-code cached review prefix stable across questions", try stableBytes(review32blocks) == stableBytes(blocks(reviewAgain.bodies[0]["messages"] as! [[String:Any]])))
  var overLimit = thirtyTwo; overLimit.references.append(first.references[0])
  do { _ = try Subject.strictAnswerMessages(overLimit); check("33 code generation references held", false) } catch { check("33 code generation references held", true) }
  let refusedReview = Subject(), refused = try await refusedReview.reviewResult(draft, overLimit)
  check("33 code review references held with nil approval/zero transport", refused == nil && refusedReview.bodies.isEmpty)
  check("actual engine code retrieval requests32", Subject.actualEngineReferenceLimit("revision-a", strict: true) == 32)
  check("actual ordinary strict remains12/general remains2", Subject.actualEngineReferenceLimit(nil, strict: true) == 12 && Subject.actualEngineReferenceLimit(nil, strict: false) == 2)
  var notesChanged = second
  for i in notesChanged.references.indices { notesChanged.references[i].note = i < 2 ? "Current routes2; omitted helper must check" : "Current varying note\(i)" }
  let current = blocks(try Subject.strictAnswerMessages(notesChanged))
  check("different current notes/UI counts never alter immutable source prefix", try stableBytes(current) == stableBytes(generationA))
  let noteGroups = try object(current.last!)["current_evidence_metadata"] as! [[String:Any]]
  check("current metadata retained with grouped exact passage IDs", noteGroups.count == 3 && noteGroups.contains { $0["retrieval_note"] as? String == "Current routes2; omitted helper must check" && $0["evidence_ids"] as? [String] == ["p0","p1"] } && noteGroups.contains { $0["evidence_ids"] as? [String] == ["p3"] })
  check("stable blocks omit retrieval notes", try items(Array(current.dropLast()), "passages").allSatisfy { $0["retrieval_note"] == nil })
  let notesReview = Subject(); try await notesReview.review(draft, notesChanged)
  let currentReview = blocks(notesReview.bodies[0]["messages"] as! [[String:Any]])
  check("review also isolates current notes into suffix", try stableBytes(currentReview) == stableBytes(reviewA) && (object(currentReview.last!)["current_evidence_metadata"] as! [[String:Any]]).count == 3)
  check("same primary first block survives different related sets", try bytes(expandedBlocks[0]) == bytes(generationA[0]) && bytes(expandedReview[0]) == bytes(reviewA[0]))
  check("at most2 explicit markers for32 references", blocks32.filter { $0["cache_control"] != nil }.count == 2 && review32blocks.filter { $0["cache_control"] != nil }.count == 2 && blocks32.dropFirst().dropLast(2).allSatisfy { $0["cache_control"] == nil })
  check("every generation/review evidence ID occurs exactly once", try items(blocks32,"passages").map { $0["id"] as! String } == expected32 + ["p2","p3"] && Set(items(review32blocks,"available_evidence").map { $0["id"] as! String }).count == thirtyTwo.references.count)
  var one = first; one.references = [first.references[0]]
  check("one stable source block has exactly one breakpoint", try blocks(Subject.strictAnswerMessages(one)).filter { $0["cache_control"] != nil }.count == 1)
  var primaryChanged = first; primaryChanged.references[0] = .init(documentName:"logic.js",text:"changed original code",repositoryCitation:first.references[0].repositoryCitation,repositoryContextRole:"module")
  check("changed primary bytes invalidate first prefix block", try bytes(blocks(Subject.strictAnswerMessages(primaryChanged))[0]) != bytes(generationA[0]))
  var scope = first; scope.repositoryRuntimeScopeID = "server"
  check("runtime scope invalidates prefix", try bytes(blocks(Subject.strictAnswerMessages(scope))[0]) != bytes(generationA[0]))
  var newSource = first
  for i in newSource.references.indices where newSource.references[i].repositoryCitation != nil { newSource.references[i].repositoryCitation!.revision = "new-source-revision" }
  check("uniform new source revision invalidates primary prefix", try bytes(blocks(Subject.strictAnswerMessages(newSource))[0]) != bytes(generationA[0]))
  var changed = first; var c = changed.references[0].repositoryCitation!; c.revision = "revision-b"
  changed.references[0] = .init(documentName: "logic.js", text: "changed", repositoryCitation: c, repositoryContextRole: "module")
  do { _ = try Subject.strictAnswerMessages(changed); check("mixed source revisions held", false) } catch { check("mixed source revisions held", true) }
  var invalid = first; invalid.references[0].repositoryContextRole = "model-invented"
  do { _ = try Subject.strictAnswerMessages(invalid); check("unknown source roles held", false) } catch { check("unknown source roles held", true) }
  var large = first; large.callBrief = String(repeating: "x", count: RepositoryPromptCache.maximumEncodedBytes)
  do { _ = try Subject.strictAnswerMessages(large); check("oversized suffix held before transport", false) } catch { check("oversized suffix held before transport", true) }
  do { _ = try RepositoryPromptCache.encodedBody(["max_tokens": 99999], required: true); check("unknown output budget held", false) } catch { check("unknown output budget held", true) }
  var ordinary = first; ordinary.usesRepository = false
  check("ordinary document wire behavior unchanged", try Subject.strictAnswerMessages(ordinary)[0]["content"] as? String == Subject.strictAnswerContent(ordinary))
  check("ordinary request not given source cache", try Subject.strictAnswerMessages(ordinary)[0]["content"] is String)
 } catch { failures += 1; print("FAIL harness \(error)") }
 print("REPOSITORY CACHE: \(checks) checks; \(failures) failures; inert transport only, no cache/model/native acceptance")
 exit(failures == 0 ? 0 : 1)
}
dispatchMain()
'''
with tempfile.TemporaryDirectory(prefix='parrot-repository-cache-', dir=args.work_root) as directory:
    temp = Path(directory)
    (temp/'Subject.swift').write_text(subject); (temp/'main.swift').write_text(main)
    sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
    subprocess.run(['swiftc','-swift-version','5','-target',platform.machine()+'-apple-macosx14.0','-sdk',sdk,str(temp/'Subject.swift'),str(temp/'main.swift'),'-o',str(temp/'checks')], check=True, timeout=120)
    raise SystemExit(subprocess.run([str(temp/'checks')],timeout=20).returncode)
