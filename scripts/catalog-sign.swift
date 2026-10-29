// Local artifact signer. The private key is never needed by Parrot or CI.
import Foundation
import CryptoKit

@main
enum CatalogSigner {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "init-key" {
            let url = URL(fileURLWithPath: args[1])
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let key: Curve25519.Signing.PrivateKey
            if FileManager.default.fileExists(atPath: url.path) {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: url))
            } else {
                key = Curve25519.Signing.PrivateKey()
                try key.rawRepresentation.write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Public verification material only. Never print the private bytes.
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        guard args.count == 5, args[0] == "sign" else {
            throw NSError(domain: "CatalogSigner", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Use init-key KEY or sign KEY PAYLOAD APPROVED_PAYLOAD_SHA256 OUTPUT"])
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == args[3], digest.count == 64 else {
            throw NSError(domain: "CatalogSigner", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Payload differs from the independently approved digest; nothing signed"])
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:
            Data(contentsOf: URL(fileURLWithPath: args[1])))
        let envelope: [String: Any] = ["format": "parrot-reviewed-answers-signed-v1",
            "payload": payload.base64EncodedString(),
            "signature": try key.signature(for: payload).base64EncodedString()]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let output = URL(fileURLWithPath: args[4])
        try data.write(to: output, options: .atomic)
        guard try Data(contentsOf: output) == data else {
            throw NSError(domain: "CatalogSigner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Signature file readback failed"])
        }
        print("Signed approved payload " + digest)
    }
}
