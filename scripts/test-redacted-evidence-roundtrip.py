#!/usr/bin/env python3
"""Actual Redactor evidence round-trip; fictional data, no app/key/model/audio.

Run on a Mac with Swift. --source-ref + --expect-red measures an old source
baseline; compilation failure never counts as the expected regression failure.
"""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref")
parser.add_argument("--expect-red", action="store_true")
args = parser.parse_args()
if args.expect_red and not args.source_ref:
    parser.error("--expect-red requires --source-ref")
root = Path(__file__).resolve().parents[1]


def read(relative):
    if args.source_ref:
        return subprocess.run(["git", "show", f"{args.source_ref}:{relative}"],
                              cwd=root, check=True, text=True, capture_output=True).stdout
    return (root / relative).read_text()


def method(source, name):
    start = source.index(name)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


def structure(source, name):
    start = source.index("struct " + name + " {")
    return source[start:source.index("\n}", start) + len("\n}")]


redactor = read("Parrot/Services/Redactor.swift")
provider = read("Parrot/Services/AnalysisProvider.swift")
switching = read("Parrot/Services/OpenAICompatibleProvider.swift")
kb = read("Parrot/Models/KnowledgeBase.swift")
subject = redactor[:redactor.index("// MARK: - Requests and results")]
subject += "\n" + (root / "Parrot/Services/RepositoryKnowledge.swift").read_text()
# Historical implementation runs against today's transport structures; the
# extra optional index field defaults to nil in the old restoration method.
# This is an old-function regression control, never an old full-app execution.
transport = (root / "Parrot/Services/AnalysisProvider.swift").read_text()
facts = (root / "Parrot/Services/ReviewedFacts.swift").read_text()
scope = (root / "Parrot/Services/ReviewedQuestionScope.swift").read_text()
subject += "\n" + next(line for line in scope.splitlines() if line.startswith("enum ReviewedSourceAuthority:"))
subject += "\nenum ReviewedAnswerCatalog {\n" + method(facts, "    struct FactCitation:") + "\n}\n"
subject += "\n" + "\n".join(structure(transport, name) for name in ("InsightDraft", "AnalysisResult"))
subject += "\n" + structure(kb, "KBReference")
subject += "\nextension Redactor {\n"
if "static func canonicalEvidence(" in redactor:
    subject += method(redactor, "    static func canonicalEvidence(") + "\n"
subject += method(redactor, "    func restore(_ r: AnalysisResult") + "\n}\n"
subject += "\nenum ClaudeAnalysisProvider {\n"
subject += next(line for line in provider.splitlines() if "static let checkFirstMessage =" in line) + "\n"
subject += method(provider, "    private static func checkFirstDraft(") + "\n"
subject += method(provider, "    static func applyingEvidenceReview(") + "\n}\n"
subject += "\nfunc evaluate(_ redactor: Redactor, _ result: AnalysisResult, _ original: [KBReference], _ redacted: [KBReference], strict: Bool = true) -> AnalysisResult {\n"
if "requireStrictEvidence: Bool" in redactor:
    subject += "return redactor.restore(result, originalReferences: original, redactedReferences: redacted, requireStrictEvidence: strict)\n"
else:
    subject += "return redactor.restore(result)\n"
subject += "}\n"
wiring = all(term in switching for term in (
    "let redacted = redactor.redact(outgoing)",
    "liveProvider.analyze(redacted)",
    "originalReferences: outgoing.references, redactedReferences: redacted.references",
    "requireStrictEvidence: request.currentQuestion != nil",
    "(!request.allowGeneralKnowledge || request.usesReviewedFacts)",
))
main = r'''
import Foundation
var checks = 0
var failures = 0
func check(_ name: String, _ pass: Bool) {
    checks += 1
    if !pass { failures += 1; print("FAIL " + name) }
}
func same(_ a: KBReference, _ b: KBReference) -> Bool {
    a.documentName == b.documentName && a.note == b.note && a.text == b.text
}
func pairs(_ refs: [KBReference], _ redactor: inout Redactor) -> [KBReference] {
    refs.map { KBReference(documentName: $0.documentName, note: $0.note, text: redactor.redact($0.text)) }
}
func packet(_ draft: InsightDraft) -> AnalysisResult {
    AnalysisResult(insights: [draft], sentiment: ["score": 50], read: "read [EMAIL_1]",
                   coach: "coach [EMAIL_1]", resolved: ["resolved [EMAIL_1]"])
}
func grounded(_ refs: [KBReference], sources: [String]? = nil, source: String? = nil,
              indices: [Int]? = nil) -> InsightDraft {
    var names: [String] = []
    for ref in refs where !names.contains(ref.documentName) { names.append(ref.documentName) }
    return InsightDraft(kindKey: "answer", title: "From your docs", detail: "old redacted detail",
        source: source ?? names.joined(separator: "; "), reply: "Use [EMAIL_1].",
        supersedes: "supersedes [EMAIL_1]", evidenceQuote: "old redacted quote",
        answerKey: "Where should [EMAIL_1] go?", evidenceSources: sources ?? names,
        evidenceReferences: refs, evidenceReferenceIndices: indices ?? Array(refs.indices))
}
func rejected(_ result: AnalysisResult) -> Bool {
    guard let draft = result.insights.first else { return false }
    return draft.source == nil && draft.reply == nil && draft.evidenceQuote == nil &&
        draft.evidenceReferences == nil && draft.evidenceSources == nil &&
        draft.detail == ClaudeAnalysisProvider.checkFirstMessage
}

var r = Redactor(hideNames: false)
let originals = [
    KBReference(documentName: "Fictional Atlas", note: "one", text: "Write atlas@fictional.example."),
    KBReference(documentName: "Fictional Atlas", note: "two", text: "Call beta@fictional.example."),
    KBReference(documentName: "Fictional Beacon", note: nil, text: "Keep the accent: café."),
]
let redacted = pairs(originals, &r)
let selected = [redacted[1], redacted[0], redacted[1], redacted[2]]
let expected = [originals[1], originals[0], originals[1], originals[2]]
let result = evaluate(r, packet(grounded(selected, indices: [1, 0, 1, 2])), originals, redacted)
let answer = result.insights[0]
check("selected sources survive", answer.evidenceSources == ["Fictional Atlas", "Fictional Beacon"])
check("original source name survives", answer.source == "Fictional Atlas; Fictional Beacon")
check("all four selected chunks survive", answer.evidenceReferences?.count == expected.count)
check("order, notes, text and multiplicity survive", answer.evidenceReferences.map { refs in
    refs.count == expected.count && zip(refs, expected).allSatisfy { same($0, $1) }
} == true)
check("canonical quote rebuilt", answer.evidenceQuote == expected.map(\.text).joined(separator: "\n\n"))
check("canonical detail uses original indices", answer.detail == zip([1, 0, 1, 2], expected).map {
    "[p\($0.0)] \($0.1.documentName)\n\($0.1.text)"
}.joined(separator: "\n\n"))
check("exact selected indices survive", answer.evidenceReferenceIndices == [1, 0, 1, 2])
check("answer still restored", answer.reply == "Use atlas@fictional.example.")
check("question key still restored", answer.answerKey == "Where should atlas@fictional.example go?")
check("other result fields survive", result.sentiment == ["score": 50] && result.read == "read atlas@fictional.example" &&
      result.coach == "coach atlas@fictional.example" && result.resolved == ["resolved atlas@fictional.example"])

var literal = Redactor(hideNames: false)
let literalOriginal = [KBReference(documentName: "Literal [EMAIL_1] title", note: "Literal [EMAIL_1] note",
    text: "Keep literal [EMAIL_1]; contact atlas@fictional.example.")]
let literalRedacted = pairs(literalOriginal, &literal)
let literalAnswer = evaluate(literal, packet(grounded(literalRedacted)), literalOriginal, literalRedacted).insights[0]
check("canonical literal quote is byte exact", literalAnswer.evidenceQuote == literalOriginal[0].text)
check("canonical reference is byte exact", literalAnswer.evidenceReferences?.first.map { same($0, literalOriginal[0]) } == true)
check("metadata placeholders never substituted", literalAnswer.evidenceSources == [literalOriginal[0].documentName] &&
      literalAnswer.source == literalOriginal[0].documentName && literalAnswer.evidenceReferences?.first?.note == literalOriginal[0].note)
check("detail preserves canonical literals", literalAnswer.detail == "[p0] Literal [EMAIL_1] title\n" + literalOriginal[0].text)

var collision = Redactor(hideNames: false)
let collisionOriginal = [
    KBReference(documentName: "Collision", note: nil, text: "Write atlas@fictional.example."),
    KBReference(documentName: "Collision", note: nil, text: "Write [EMAIL_1]."),
]
let collisionRedacted = pairs(collisionOriginal, &collision)
check("fixture creates real placeholder collision", same(collisionRedacted[0], collisionRedacted[1]))
check("different originals with same redacted triple fail closed",
      rejected(evaluate(collision, packet(grounded([collisionRedacted[0]])), collisionOriginal, collisionRedacted)))

let duplicatesOriginal = [originals[0], originals[0]]
var duplicates = Redactor(hideNames: false)
let duplicatesRedacted = pairs(duplicatesOriginal, &duplicates)
let duplicateAnswer = evaluate(duplicates, packet(grounded(duplicatesRedacted, indices: [1, 0])), duplicatesOriginal, duplicatesRedacted).insights[0]
check("identical duplicate references accepted", duplicateAnswer.evidenceReferences?.count == 2 && duplicateAnswer.reply != nil)
check("duplicate order and multiplicity retained", duplicateAnswer.evidenceReferences.map {
    $0.count == 2 && $0.allSatisfy { same($0, originals[0]) }
} == true)
check("identical duplicate passage identities do not collapse", duplicateAnswer.evidenceReferenceIndices == [1, 0] &&
      duplicateAnswer.detail == "[p1] Fictional Atlas\n" + originals[0].text + "\n\n[p0] Fictional Atlas\n" + originals[0].text)

let unknown = KBReference(documentName: "Fictional Atlas", note: "one", text: "Unreturned bytes")
check("unknown selected chunk fails closed", rejected(evaluate(r, packet(grounded([unknown])), originals, redacted)))
check("mismatched request lengths fail closed", rejected(evaluate(r, packet(grounded([redacted[0]])), originals, [redacted[0]])))
check("invented source list fails closed", rejected(evaluate(r,
    packet(grounded([redacted[0]], sources: ["Invented"])), originals, redacted)))
check("invented source field fails closed", rejected(evaluate(r,
    packet(grounded([redacted[0]], source: "Invented")), originals, redacted)))
check("out-of-bounds index fails closed", rejected(evaluate(r,
    packet(grounded([redacted[0]], indices: [9])), originals, redacted)))
check("wrong request index fails closed", rejected(evaluate(r,
    packet(grounded([redacted[0]], indices: [1])), originals, redacted)))
check("wrong index count fails closed", rejected(evaluate(r,
    packet(grounded([redacted[0]], indices: [])), originals, redacted)))
var noIndices = grounded([redacted[0]])
noIndices.evidenceReferenceIndices = nil
check("cited answer missing app-selected indices fails closed", rejected(evaluate(r, packet(noIndices), originals, redacted)))
let missing = InsightDraft(kindKey: "answer", title: "answer", detail: "claim", source: "Fictional Atlas",
    reply: "Some claim.", answerKey: "Where should [EMAIL_1] go?")
let missingResult = evaluate(r, packet(missing), originals, redacted)
check("strict grounded answer without refs fails closed", rejected(missingResult))
check("rejection keeps restored question identity", missingResult.insights[0].answerKey == "Where should atlas@fictional.example go?")
var empty = missing
empty.evidenceReferences = []
empty.evidenceSources = []
check("strict grounded answer with empty refs fails closed", rejected(evaluate(r, packet(empty), originals, redacted)))

let uncertain = InsightDraft(kindKey: "answer", title: "Check first", detail: "check [EMAIL_1]", source: nil,
    reply: "I haven't verified that. Check a copy.", answerKey: "Where should [EMAIL_1] go?")
let nilFields = evaluate(r, packet(uncertain), originals, redacted).insights[0]
check("source-free uncertainty survives", nilFields.reply == uncertain.reply && nilFields.source == nil)
check("nil arrays remain nil", nilFields.evidenceSources == nil && nilFields.evidenceReferences == nil)
var emptyUncertain = uncertain
emptyUncertain.evidenceSources = []
emptyUncertain.evidenceReferences = []
let emptyFields = evaluate(r, packet(emptyUncertain), originals, redacted).insights[0]
check("empty arrays remain empty", emptyFields.evidenceSources?.isEmpty == true && emptyFields.evidenceReferences?.isEmpty == true)
let legacy = evaluate(r, packet(missing), originals, redacted, strict: false).insights[0]
check("legacy non-strict answer without evidence unchanged", legacy.source == missing.source && legacy.reply == missing.reply)
'''
main += f'\ncheck("actual switching forwards paired requests and strict policy", {str(wiring).lower()})\n'
main += 'print("redacted evidence: \\(checks) checks, \\(failures) failures")\nexit(failures == 0 ? 0 : 1)\n'
with tempfile.TemporaryDirectory(prefix="parrot-evidence-roundtrip-") as tmp:
    directory = Path(tmp)
    (directory / "Subject.swift").write_text(subject)
    (directory / "main.swift").write_text(main)
    compiled = subprocess.run(["swiftc", "-target", platform.machine() + "-apple-macosx14.0",
                               "-sdk", subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip(),
                               str(directory / "Subject.swift"), str(directory / "main.swift"),
                               "-o", str(directory / "checks")], text=True, capture_output=True)
    if compiled.returncode:
        print(compiled.stdout, end="")
        print(compiled.stderr, end="")
        raise SystemExit(2)
    run = subprocess.run([str(directory / "checks")], text=True, capture_output=True)
    print(run.stdout, end="")
    print(run.stderr, end="")
    if args.expect_red:
        if run.returncode != 1 or "FAIL " not in run.stdout:
            raise SystemExit("Expected actual assertion failures, not a passing baseline or runtime error")
        print("EXPECTED_RED: compiled old actual source; assertions failed")
        raise SystemExit(0)
    raise SystemExit(run.returncode)
