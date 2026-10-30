import Foundation

/// These checks catch false semantic PASS from malformed or transport fallback.
/// They inspect real response parsing; no HTTP/key/model access.
enum ReviewedSelectorObservationChecks {
    static let ambiguousSelectionTexts = [
        #"{"mode":"answer","mode":"uncertain","unit_id":"a-example","unit_id":""}"#,
        #"{"mode":"uncertain","mode":"answer","unit_id":"","unit_id":"a-example"}"#,
        #"{"mode":"uncertain","mode":"uncertain","unit_id":""}"#,
        #"{"mode":"answer","\u006dode":"uncertain","unit_id":"a-example","unit_id":""}"#,
        #"{"mode":"uncertain","mode":"answer","mode":"uncertain","unit_id":""}"#
    ]
    static func run(_ check: (String, Bool) -> Void) {
        func envelope(_ object: [String: Any], stop: String = "end_turn",
                      blocks: Int = 1) -> Data {
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let block: [String: Any] = ["type": "text", "text": text]
            return try! JSONSerialization.data(withJSONObject: [
                "id": "fictional-message", "type": "message", "role": "assistant",
                "model": "fictional-model", "content": Array(repeating: block, count: blocks),
                "stop_reason": stop, "usage": ["input_tokens": 10, "output_tokens": 5]
            ])
        }
        let known: Set<String> = ["a-example"]
        let uncertain: [String: Any] = ["mode": "uncertain", "unit_id": ""]
        let selected: [String: Any] = ["mode": "answer", "unit_id": "a-example"]
        let good = ReviewedSelectorObservation.inspect(envelope(selected), allowedAnswerIDs: known)
        check("selector observation records a valid known selection", good.kind == .answer && good.unitID == "a-example")
        let abstention = ReviewedSelectorObservation.inspect(envelope(uncertain), allowedAnswerIDs: known)
        check("selector observation recognizes valid semantic uncertainty", abstention.kind == .uncertain && abstention.unitID == nil)
        let absent = ReviewedSelectorObservation.inspect(nil, allowedAnswerIDs: known)
        check("selector observation keeps no response inconclusive", absent.kind == .noResponse && absent.unitID == nil)
        let invalid: [(String, Data)] = [
            ("uncertain with a factual ID", envelope(["mode": "uncertain", "unit_id": "a-example"])),
            ("unknown positive ID", envelope(["mode": "answer", "unit_id": "a-unknown"])),
            ("known ID outside candidates", envelope(selected)),
            ("empty positive ID", envelope(["mode": "answer", "unit_id": ""])),
            ("non-string ID", envelope(["mode": "answer", "unit_id": 7])),
            ("null ID", envelope(["mode": "uncertain", "unit_id": NSNull()])),
            ("missing ID", envelope(["mode": "uncertain"])),
            ("unrecognized mode", envelope(["mode": "sure", "unit_id": "a-example"])),
            ("extra factual field", envelope(["mode": "answer", "unit_id": "a-example", "reply": "Edited"])),
            ("truncated metered uncertain", envelope(uncertain, stop: "max_tokens")),
            ("truncated metered answer", envelope(selected, stop: "max_tokens")),
            ("missing text block", envelope(uncertain, blocks: 0)),
            ("multiple text blocks", envelope(uncertain, blocks: 2)),
            ("malformed envelope", Data("{broken".utf8)),
            ("oversized response", Data(repeating: 32, count: 65_537)),
            ("server error envelope", Data(#"{"error":{"message":"fictional"},"usage":{"input_tokens":10,"output_tokens":5}}"#.utf8))
        ]
        for (name, data) in invalid {
            let allowed: Set<String> = name == "known ID outside candidates" ? [] : known
            let value = ReviewedSelectorObservation.inspect(data, allowedAnswerIDs: allowed)
            check("selector observation never certifies " + name, value.kind == .invalid && value.unitID == nil)
        }
        // Correlation must be supplied by one fresh observation per invocation.
        // A later missing response cannot retain the prior valid abstention.
        let first = ReviewedSelectorObservation.inspect(envelope(uncertain), allowedAnswerIDs: known)
        let second = ReviewedSelectorObservation.inspect(nil, allowedAnswerIDs: known)
        check("selector observations do not carry prior uncertainty into no response",
              first.kind == .uncertain && second.kind == .noResponse)
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let capture = ReviewedSelectorObservationCapture(invocationID: token)
        capture.record(abstention, invocationID: token)
        check("selector capture accepts its one correlated response", capture.observation == abstention)
        let stale = ReviewedSelectorObservationCapture(invocationID: token)
        stale.record(abstention, invocationID: other)
        check("selector capture rejects a prior invocation", stale.observation?.kind == .invalid)
        capture.record(abstention, invocationID: token)
        check("selector capture rejects a duplicate observation", capture.observation?.kind == .invalid)
        let fresh = ReviewedSelectorObservationCapture(invocationID: other)
        check("selector capture starts each invocation empty", fresh.observation == nil)
        for (index, text) in ambiguousSelectionTexts.enumerated() {
            let outer = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": text]], "stop_reason": "end_turn",
                "usage": ["input_tokens": 10, "output_tokens": 5]
            ])
            let value = ReviewedSelectorObservation.inspect(outer, allowedAnswerIDs: known)
            check("selector observation rejects ambiguous duplicate keys " + String(index), value.kind == .invalid)
        }
        let validRaw: [(String, String, String?)] = [
            (#" { "\u006dode" : "uncertain", "unit_id" : "" } "#, "uncertain", nil),
            (#" { "unit_id" : "a-example", "mode" : "answer" } "#, "answer", "a-example")
        ]
        for (index, item) in validRaw.enumerated() {
            let outer = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": item.0]], "stop_reason": "end_turn"
            ])
            let value = ReviewedSelectorObservation.inspect(outer, allowedAnswerIDs: known)
            check("selector observation preserves valid escaped/order variant " + String(index),
                  value.kind.rawValue == item.1 && value.unitID == item.2)
        }
    }
}

