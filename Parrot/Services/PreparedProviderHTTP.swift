import Foundation
import CoreFoundation
import CryptoKit

/// Metadata for the prepared-body experiment only; never native answer acceptance.
/// Response limits below apply AFTER URLSession buffers the body, not to network memory.
enum PreparedProviderHTTP {
    typealias Observer = (Int?, Data?, UInt64, UInt64, Data) -> Void
    static let maximumRetainedResponseBytes = 16_384
    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Usage: Encodable {
        let input: Int?, output: Int?, creation: Int?, read: Int?
        let creationByTTL: [String: Int]?
        let state: String
        var cacheClassification: String {
            guard state != "invalid" else { return "unknown" }
            if let read, read > 0 { return "observed_cache_read" }
            if read == 0, let creation, creation > 0 { return "observed_creation_without_read" }
            if read == 0, creation == 0 { return "reported_zero_read_and_creation" }
            return "unknown"
        }
        private enum CodingKeys: String, CodingKey {
            case input = "input_tokens", output = "output_tokens"
            case creation = "cache_creation_input_tokens", read = "cache_read_input_tokens"
            case creationByTTL = "cache_creation", state
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(input, forKey: .input); try c.encode(output, forKey: .output)
            try c.encode(creation, forKey: .creation); try c.encode(read, forKey: .read)
            try c.encode(creationByTTL, forKey: .creationByTTL); try c.encode(state, forKey: .state)
        }
        static let unknown = Usage(input: nil, output: nil, creation: nil, read: nil,
                                   creationByTTL: nil, state: "missing")
        static func inspect(_ data: Data) -> Self {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let value = root["usage"] else { return .unknown }
            guard let usage = value as? [String: Any] else {
                return Usage(input: nil, output: nil, creation: nil, read: nil, creationByTTL: nil, state: "invalid")
            }
            var invalid = false
            func integer(_ value: Any?) -> Int? {
                guard let value, !(value is NSNull) else { return nil }
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1_000_000_000,
                      n.doubleValue.rounded(.towardZero) == n.doubleValue else { invalid = true; return nil }
                return n.intValue
            }
            let input = integer(usage["input_tokens"]), output = integer(usage["output_tokens"])
            let creation = integer(usage["cache_creation_input_tokens"]), read = integer(usage["cache_read_input_tokens"])
            var ttl: [String: Int]?
            if let value = usage["cache_creation"], !(value is NSNull) {
                if let entries = value as? [String: Any], entries.count <= 16 {
                    ttl = [:]
                    for (key, value) in entries {
                        guard key.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                            invalid = true; continue
                        }
                        if let n = integer(value) { ttl?[key] = n }
                    }
                } else { invalid = true }
            }
            return Usage(input: input, output: output, creation: creation, read: read,
                         creationByTTL: ttl, state: invalid ? "invalid" : "present")
        }
    }

    struct Result: Encodable {
        let invocationID: UUID, expectedModel: String, status: String
        let requestedModel: String?
        let appAttempts: Int, httpStatus: Int?, returnedModel: String?, modelState: String
        let actualWireSHA256: String?, actualRequestBytes: Int?
        let responseSHA256: String?, responseBytes: Int?, fullHTTPNanoseconds: UInt64?
        // Send closure only; excludes final measurement parsing/journal writes.
        let sendNanoseconds: UInt64, transportErrorCode: Int?
        let cancellationObserved: Bool
        let firstResponseText: String?, retainedResponse: Data?, stopReason: String?
        let usage: Usage
        let nativeAcceptance = false, scored = false
        private enum CodingKeys: String, CodingKey {
            case invocationID, expectedModel, requestedModel, status, appAttempts, httpStatus, returnedModel, modelState
            case actualWireSHA256, actualRequestBytes, responseSHA256, responseBytes, fullHTTPNanoseconds
            case sendNanoseconds, transportErrorCode, cancellationObserved, firstResponseText, retainedResponse, stopReason
            case usage, cacheClassification, nativeAcceptance, scored
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(invocationID, forKey: .invocationID); try c.encode(expectedModel, forKey: .expectedModel)
            try c.encode(requestedModel, forKey: .requestedModel)
            try c.encode(status, forKey: .status); try c.encode(appAttempts, forKey: .appAttempts)
            try c.encode(httpStatus, forKey: .httpStatus); try c.encode(returnedModel, forKey: .returnedModel)
            try c.encode(modelState, forKey: .modelState); try c.encode(actualWireSHA256, forKey: .actualWireSHA256)
            try c.encode(actualRequestBytes, forKey: .actualRequestBytes); try c.encode(responseSHA256, forKey: .responseSHA256)
            try c.encode(responseBytes, forKey: .responseBytes); try c.encode(fullHTTPNanoseconds, forKey: .fullHTTPNanoseconds)
            try c.encode(sendNanoseconds, forKey: .sendNanoseconds); try c.encode(transportErrorCode, forKey: .transportErrorCode)
            try c.encode(cancellationObserved, forKey: .cancellationObserved)
            try c.encode(firstResponseText, forKey: .firstResponseText); try c.encode(retainedResponse, forKey: .retainedResponse)
            try c.encode(stopReason, forKey: .stopReason); try c.encode(usage, forKey: .usage)
            try c.encode(usage.cacheClassification, forKey: .cacheClassification)
            try c.encode(false, forKey: .nativeAcceptance); try c.encode(false, forKey: .scored)
        }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0, closed = false
        private var status: Int?, data: Data?, responseHash: String?, responseBytes: Int?
        private var requestedModel: String?
        private var started: UInt64?, finished: UInt64?, wireHash: String?, wireBytes: Int?
        func observe(status: Int?, data: Data?, started: UInt64, finished: UInt64, wire: Data) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return } // Observer is never retained by the synchronous transport callback.
            attempts += 1
            guard attempts == 1 else { return }
            self.status = status; self.started = started; self.finished = finished
            wireHash = PreparedProviderHTTP.sha(wire); wireBytes = wire.count
            if let body = (try? JSONSerialization.jsonObject(with: wire)) as? [String: Any],
               body["model"] as? String == "claude-haiku-5-5" { requestedModel = "claude-haiku-5-5" }
            responseBytes = data?.count; responseHash = data.map(PreparedProviderHTTP.sha)
            // No raw error message/body, request headers, key, URL or Error description enters a record.
            if status == 200, let data, data.count <= maximumRetainedResponseBytes { self.data = data }
        }
        func result(invocationID: UUID, model: String, expectedWire: String, expectedBytes: Int,
                    error: Error?, duration: UInt64, taskCancelled: Bool) -> Result {
            lock.lock(); defer { lock.unlock() }; closed = true
            let metadata = data.map { AnswerTraceHTTPResponse.inspect(statusCode: status, data: $0) }
            let usage = data.map(Usage.inspect) ?? .unknown
            let root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            // Keep the complete first response, not just its first text block.
            // Newlines preserve block boundaries; raw response bytes remain available.
            let text: String? = {
                guard let blocks = root?["content"] as? [[String: Any]] else { return nil }
                let answers = blocks.filter { $0["type"] as? String == "text" }
                let strings = answers.compactMap { $0["text"] as? String }
                guard !answers.isEmpty, strings.count == answers.count else { return nil }
                return strings.joined(separator: "\n")
            }()
            let stop = (root?["stop_reason"] as? String).flatMap {
                $0.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil ? $0 : nil
            }
            let transportCode = (error as? URLError)?.code.rawValue
            let cancelled = taskCancelled || error is CancellationError || transportCode == URLError.cancelled.rawValue
            let elapsed: UInt64? = {
                guard let started, let finished, finished >= started else { return nil }
                return finished - started
            }()
            let outcome: String
            if attempts == 0, cancelled { outcome = "cancelled" }
            else if attempts != 1 || wireHash != expectedWire || wireBytes != expectedBytes || elapsed == nil {
                outcome = "observation_invalid_or_not_started"
            } else if let status, status != 200 { outcome = "http_error" }
            else if transportCode == URLError.timedOut.rawValue { outcome = "timeout" }
            else if error is CancellationError || transportCode == URLError.cancelled.rawValue { outcome = "cancelled" }
            else if status == nil { outcome = "transport_error" }
            else if responseBytes.map({ $0 > maximumRetainedResponseBytes }) == true { outcome = "response_too_large" }
            else if requestedModel != model || requestedModel == nil { outcome = "requested_model_unverified" }
            else if metadata?.modelState != .recognized { outcome = "model_metadata_unverified" }
            else if error != nil { outcome = "provider_error" }
            else if text == nil { outcome = "response_text_missing" }
            else if cancelled { outcome = "cancelled" }
            else { outcome = "response_unscored" }
            return Result(invocationID: invocationID, expectedModel: model, status: outcome,
                          requestedModel: requestedModel,
                          appAttempts: attempts, httpStatus: status, returnedModel: metadata?.returnedModel,
                          modelState: metadata?.modelState.rawValue ?? "unavailable",
                          actualWireSHA256: wireHash, actualRequestBytes: wireBytes,
                          responseSHA256: responseHash, responseBytes: responseBytes, fullHTTPNanoseconds: elapsed,
                          sendNanoseconds: duration, transportErrorCode: transportCode,
                          cancellationObserved: cancelled,
                          firstResponseText: text, retainedResponse: data, stopReason: stop, usage: usage)
        }
    }

    /// One app data task; caller must disable application retries. Timings here
    /// exclude audio/ASR/UI and cannot establish the two-second native target.
    static func measure(invocationID: UUID, model: String, expectedWireSHA256: String,
                        expectedBytes: Int, send: (@escaping Observer) async throws -> Data) async -> Result {
        let capture = Capture()
        let began = DispatchTime.now().uptimeNanoseconds
        var failure: Error?
        do {
            try Task.checkCancellation()
            _ = try await send { status, data, began, ended, wire in
                capture.observe(status: status, data: data, started: began, finished: ended, wire: wire)
            }
        } catch { failure = error }
        return capture.result(invocationID: invocationID, model: model, expectedWire: expectedWireSHA256,
                              expectedBytes: expectedBytes, error: failure,
                              duration: DispatchTime.now().uptimeNanoseconds - began,
                              taskCancelled: Task.isCancelled)
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static func session(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
}

