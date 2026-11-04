import Foundation

/// Explicit source-prefix caching is configuration, not a cache-hit, account
/// admission or readiness claim. All bytes here are already privacy-filtered.
enum RepositoryPromptCache {
    enum Failure: LocalizedError {
        case held(String)
        var errorDescription: String? { switch self { case .held(let reason): return "Code context on hold: " + reason } }
    }
    static let maximumEncodedBytes = 768 * 1024
    // Conservative UTF-8-byte upper bound plus framing/output reserve. This is
    // not the vendor token-count endpoint or proof of this account's capacity.
    static let maximumTokenUpperBound = 900_000

    static func messages(content: [String: Any], evidence: [[String: Any]],
                         references: [KBReference], evidenceKey: String,
                         runtimeScopeID: String?) throws -> [[String: Any]] {
        guard let scope = runtimeScopeID, !scope.isEmpty, evidence.count == references.count,
              references.contains(where: { $0.repositoryCitation != nil }),
              references.filter({ $0.repositoryCitation != nil }).count <= 32 else { throw Failure.held("source/scope inventory") }
        let allowedRoles: Set<String> = ["module", "loader", "related_declarations", "ui"]
        for ref in references where ref.repositoryContextRole != nil {
            guard ref.repositoryCitation != nil, allowedRoles.contains(ref.repositoryContextRole!) else { throw Failure.held("unknown source role") }
        }
        guard Set(references.compactMap { $0.repositoryCitation?.revision }).count == 1 else { throw Failure.held("mixed source revisions") }
        let stable = references.indices.filter { ["module", "loader", "related_declarations"].contains(references[$0].repositoryContextRole ?? "") }
        let stableSet = Set(stable)
        // Request-current status is data for the model/reviewer, not part of
        // immutable code-prefix identity. Group identical notes once per ID set.
        var clean = evidence, noteOrder: [String] = [], noteIDs: [String: [String]] = [:]
        for i in references.indices {
            let notes = [references[i].note, evidence[i]["retrieval_note"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            for note in notes {
                if noteIDs[note] == nil { noteOrder.append(note); noteIDs[note] = [] }
                let id = "p\(i)"
                if !noteIDs[note]!.contains(id) { noteIDs[note]!.append(id) }
            }
            clean[i].removeValue(forKey: "retrieval_note")
        }
        var suffix = content; suffix[evidenceKey] = clean.indices.filter { !stableSet.contains($0) }.map { clean[$0] }
        suffix["current_evidence_metadata"] = noteOrder.map { ["evidence_ids": noteIDs[$0]!, "retrieval_note": $0] as [String: Any] }
        func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        var blocks: [[String: Any]] = []
        if !stable.isEmpty {
            let revisions = Set(stable.compactMap { references[$0].repositoryCitation?.revision })
            guard revisions.count == 1 else { throw Failure.held("mixed source revisions") }
            for (position, index) in stable.enumerated() {
                let prefix: [String: Any] = ["source_context": "exact original module/related-declaration/declared-loader span; broad evidence, not pinpoint spans or execution proof",
                    "selected_runtime": scope, "source_revision": revisions.first!, evidenceKey: [clean[index]]]
                var block: [String: Any] = ["type": "text", "text": try json(prefix)]
                if position == 0 || position == stable.count - 1 { block["cache_control"] = ["type": "ephemeral", "ttl": "1h"] }
                blocks.append(block)
            }
        }
        blocks.append(["type": "text", "text": try json(suffix)])
        let messages: [[String: Any]] = [["role": "user", "content": blocks]]
        _ = try encodedBody(["messages": messages], required: true)
        return messages
    }

    static func encodedBody(_ body: [String: Any], required: Bool) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        if required {
            let output = body["max_tokens"] as? Int ?? 2048
            guard output >= 0, output <= 4096, bytes.count <= maximumEncodedBytes,
                  bytes.count + 8192 + output <= maximumTokenUpperBound else { throw Failure.held("encoded byte/conservative token budget; real token/account admission still required") }
        }
        return bytes
    }
}
