import Foundation

/// Exact-QA, no-audio production-selector diagnostic; never scores native answers.
enum ReviewedSelectorEval {
    enum Failure: Error { case unavailable, rejected }
    struct Evidence: Encodable {
        let documentName:String
        let text:String
    }
    struct Row: Encodable {
        let caseID:String,mode:String,invocationID:String,question:String,transcriptSHA256:String
        let observation:ReviewedSelectorObservation
        let requestStatus:String
        let elapsedNanoseconds:UInt64
        let usageCalls:Int
        let reply:String?,source:String?,selectedUnitDigest:String?
        let evidence:[Evidence]
        let outputMatchesObservedUnit:Bool
        let semanticStatus="unscored"
        let nativeAcceptance=false
    }
    static func matchesBuild(expected:String,actual:Any?) -> Bool { false }

    static func execute(prepared:ReviewedSelectorInput.Prepared,
                        makeProvider:(ReviewedSelectorObservationCapture)->AnalysisProvider,
                        record:(Row)throws->Void) async throws {
        throw Failure.unavailable
    }
}
