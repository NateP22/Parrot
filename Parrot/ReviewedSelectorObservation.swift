import Foundation

/// Response-only diagnostic. Never authorizes a reply or changes the parser.
struct ReviewedSelectorObservation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case answer, uncertain, invalid, noResponse }
    let kind: Kind
    let unitID: String?

    static func inspect(_ data: Data?, allowedAnswerIDs: Set<String>) -> Self {
        guard let data else { return Self(kind: .noResponse, unitID: nil) }
        let invalid = Self(kind: .invalid, unitID: nil)
        guard data.count <= 65_536,
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              envelope["stop_reason"] as? String == "end_turn",
              let blocks = envelope["content"] as? [[String: Any]], blocks.count == 1,
              blocks[0]["type"] as? String == "text",
              let text = blocks[0]["text"] as? String,
              hasUniqueStringFields(text),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              Set(object.keys) == Set(["mode", "unit_id"]),
              let mode = object["mode"] as? String, let id = object["unit_id"] as? String
        else { return invalid }
        if mode == "uncertain", id.isEmpty {
            return Self(kind: .uncertain, unitID: nil)
        }
        if mode == "answer", !id.isEmpty, allowedAnswerIDs.contains(id) {
            return Self(kind: .answer, unitID: id)
        }
        return invalid
    }

    /// Only the selector's two String fields are allowed. Foundation decoders
    /// collapse repeated keys, so check their spelling before object decoding.
    private static func hasUniqueStringFields(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var position = 0
        func whitespace() {
            while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }
        func string() -> String? {
            whitespace()
            guard position < bytes.count, bytes[position] == 34 else { return nil }
            let start = position
            position += 1
            while position < bytes.count {
                if bytes[position] == 92 { position += 2; continue }
                if bytes[position] == 34 {
                    position += 1
                    return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
                }
                position += 1
            }
            return nil
        }
        whitespace()
        guard position < bytes.count, bytes[position] == 123 else { return false }
        position += 1
        var keys = Set<String>()
        for index in 0..<2 {
            guard let key = string(), ["mode", "unit_id"].contains(key), keys.insert(key).inserted else { return false }
            whitespace()
            guard position < bytes.count, bytes[position] == 58 else { return false }
            position += 1
            guard string() != nil else { return false }
            whitespace()
            let delimiter: UInt8 = index == 0 ? 44 : 125
            guard position < bytes.count, bytes[position] == delimiter else { return false }
            position += 1
        }
        whitespace()
        return position == bytes.count && keys == Set(["mode", "unit_id"])
    }
}

/// Fresh per invocation; stale or duplicate callbacks remain inconclusive.
final class ReviewedSelectorObservationCapture: @unchecked Sendable {
    let invocationID: UUID
    private let lock = NSLock()
    private var value: ReviewedSelectorObservation?
    private var correlationFailed = false

    init(invocationID: UUID = UUID()) { self.invocationID = invocationID }

    func record(_ observation: ReviewedSelectorObservation, invocationID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard invocationID == self.invocationID, value == nil, !correlationFailed else {
            value = nil
            correlationFailed = true
            return
        }
        value = observation
    }

    var observation: ReviewedSelectorObservation? {
        lock.lock(); defer { lock.unlock() }
        return correlationFailed ? ReviewedSelectorObservation(kind: .invalid, unitID: nil) : value
    }
}

