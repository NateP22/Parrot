import Foundation

/// Parses only the disposable credential probe; no caller-supplied account or value.
enum QACredentialProbePolicy {
    enum Phase: String, CaseIterable, Sendable { case write, verifyCleanup = "verify-cleanup", absent }
    struct Request: Sendable {
        let phase: Phase
        let nonce: UUID
        var account: String { "qa-native-persistence-v1:" + nonce.uuidString }
        var publicFixture: String { "public-native-fixture-v1:" + nonce.uuidString }
    }
    static func request(options: [String]) -> Request? {
        guard options.count == 4, options[0] == "--qa-setup",
              options[1] == "--qa-credential-probe", let phase = Phase(rawValue: options[2]),
              let nonce = UUID(uuidString: options[3]), nonce.uuidString == options[3] else { return nil }
        return Request(phase: phase, nonce: nonce)
    }
}
