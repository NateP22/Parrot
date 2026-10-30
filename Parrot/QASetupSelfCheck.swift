import Foundation
import NaturalLanguage
import AppKit

/// Bundled CI component probe of actual model owners, not recording/native answers.
enum QASetupSelfCheck {
    private enum Owner: String, CaseIterable, Sendable { case speech, speakers, local, embedding }
    @MainActor static func run() {
        guard QASetupLaunch.isActive else { emit("REJECTED"); exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let argument = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil
        let owners: [Owner]
        if let argument {
            guard let owner = Owner(rawValue: argument) else { emit("REJECTED"); exit(2) }
            owners = [owner]
        } else { owners = Owner.allCases }
        // An absent guard must fail promptly rather than start an unbounded download.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+2) {
            emit("TIMEOUT"); exit(2)
        }
        Task { @MainActor in
            for owner in owners {
            switch owner {
            case .speech:
            let speech = TranscriptionEngine()
            await speech.loadModel("qa-settings-only-no-download")
            guard !speech.isReady, speech.loadingModelName == nil,
                  case .notLoaded = speech.modelState else { emit("SPEECH_STARTED"); exit(1) }
            case .speakers:
            let speakers = DiarizationEngine()
            do { try await speakers.ensureModels(); emit("DIARIZATION_NOT_REFUSED"); exit(1) }
            catch is QASetupLaunch.Unavailable { }
            catch { emit("DIARIZATION_WRONG_FAILURE"); exit(1) }
            guard !speakers.isProcessing else { emit("DIARIZATION_BUSY"); exit(1) }
            case .local:
            let local = OllamaService()
            guard !local.beginPull("qa-settings-only-no-download"), !local.isPulling else {
                emit("LOCAL_MODEL_STARTED"); exit(1)
            }
            case .embedding:
            // CI prepares English assets first. This makes missing embedding
            // suppression observable instead of passing because assets are absent.
            guard NLContextualEmbedding(language: .english)?.hasAvailableAssets == true else {
                emit("EMBEDDING_PREREQUISITE_MISSING"); exit(2)
            }
            guard KnowledgeBaseService.space(for: .english) == nil else {
                emit("EMBEDDING_MODEL_LOADED"); exit(1)
            }
            }
            }
            emit("PASS"); exit(0)
        }
        app.run()
        emit("EVENT_LOOP_ENDED"); exit(2)
    }
    private static func emit(_ stage: String) {
        let obj: [String:Any] = ["stage":stage,"audio_capture":false,
            "persistent_store":false,"native_acceptance":false,
            "scope":"QA setup actual model-owner component check"]
        if let data = try? JSONSerialization.data(withJSONObject:obj,options:.sortedKeys) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
}
