import Foundation

enum FrameTraceChecks {
    @MainActor static func run(_ check: (String, Bool) -> Void) {
        var deadlineReturned=false
        Task { @MainActor in
            let value: Int?=await AnswerFrameDeadline.value(seconds:0.01) { _ in }
            deadlineReturned=value == nil
        }
        let until=Date.now+1
        while !deadlineReturned && Date.now<until { RunLoop.main.run(until:.now+0.005) }
        check("frame enumeration never-callback returns at deadline", deadlineReturned)
        var firstResult: Int?
        Task { @MainActor in
            firstResult=await AnswerFrameDeadline.value(seconds:0.01) { reply in
                reply(7); reply(8)
            }
        }
        let twiceUntil=Date.now+1
        while firstResult == nil && Date.now<twiceUntil { RunLoop.main.run(until:.now+0.005) }
        check("frame enumeration callback resolves once", firstResult == 7)
        var life=AnswerFrameLifecycle()
        let a=life.begin(sessionID:UUID())!
        _ = life.start(generation:a)
        _ = life.beginStop()
        check("frame lifecycle forbids B during A finalization", life.begin(sessionID:UUID()) == nil)
        check("frame lifecycle refuses A late activation during Stop", !life.activate(generation:a))
        _ = life.finishStop(generation:a,knownStopped:false)
        check("frame unknown OS stop locks out a new capture", life.begin(sessionID:UUID()) == nil)
        _ = life.finishStop(generation:a,knownStopped:true)
        let b=life.begin(sessionID:UUID())!
        check("frame A late cleanup cannot erase B", !life.finishStop(generation:a,knownStopped:true) && life.generation == b)
        check("frame owner rejects another app", !AnswerFrameOwner.matches(windowID: 5, requestedID: 5, ownerPID: 8, ownPID: 7, onScreen: true))
        check("frame owner rejects another own window", !AnswerFrameOwner.matches(windowID: 6, requestedID: 5, ownerPID: 7, ownPID: 7, onScreen: true))
        check("frame owner rejects offscreen target", !AnswerFrameOwner.matches(windowID: 5, requestedID: 5, ownerPID: 7, ownPID: 7, onScreen: false))
        check("frame owner admits exact own visible target", AnswerFrameOwner.matches(windowID: 5, requestedID: 5, ownerPID: 7, ownPID: 7, onScreen: true))
        let off = AnswerFrameTraceRecorder(enabled: false)
        let id = UUID()
        off.start(sessionID: id, windowID: 5)
        check("frame disabled creates no session", off.snapshot().sessionID == nil)
        let trace = AnswerFrameTraceRecorder(enabled: true, frameLimit: 3)
        trace.start(sessionID: id, windowID: 5)
        var frame = AnswerFrameObservation(status: .complete, displayTicks: 100, displayNs: 1_000,
            callbackNs: 2_000, rect: [0,0,800,600], scaleFactor: 2, contentScale: 1,
            pixelWidth: 1600, pixelHeight: 1200, mediaFrameIndex: 0, mediaPTS: 0)
        check("frame complete retained pixels form a candidate only", trace.record(sessionID: id, frame: frame))
        check("frame capture never proves native visibility", !trace.snapshot().independentVisibilityVerified && !trace.snapshot().nativeAcceptance)
        var idle = frame
        idle.status = .idle; idle.displayTicks = nil; idle.displayNs = nil
        idle.mediaFrameIndex = nil; idle.mediaPTS = nil
        _ = trace.record(sessionID: id, frame: idle)
        check("frame idle is retained without inventing a new presentation", trace.snapshot().observations.count == 2 && trace.snapshot().invalidFrames == 0)
        frame.displayTicks = 200; frame.displayNs = 3_000; frame.callbackNs = 4_000
        frame.mediaFrameIndex = 1; frame.mediaPTS = 2_000
        _ = trace.record(sessionID: id, frame: frame)
        check("frame complete presentation identity remains ordered", trace.snapshot().invalidFrames == 0)
        _ = trace.record(sessionID: id, frame: frame)
        check("frame cap does not evict early wrong-answer evidence", trace.snapshot().truncated && trace.snapshot().observations.count == 3)
        trace.start(sessionID: id, windowID: 5)
        frame.displayNs = nil
        check("frame complete missing display clock rejects", !trace.record(sessionID: id, frame: frame) && trace.snapshot().invalidFrames == 1)
        trace.start(sessionID: id, windowID: 5)
        frame.displayNs = 3_000; frame.mediaFrameIndex = nil
        check("frame writer drop cannot become useful pixels", !trace.record(sessionID: id, frame: frame) && trace.snapshot().invalidFrames == 1)
        trace.start(sessionID: id, windowID: 5)
        frame.mediaFrameIndex = 0; frame.mediaPTS = 0
        _ = trace.record(sessionID: id, frame: frame)
        _ = trace.record(sessionID: id, frame: frame)
        check("frame repeated display clock is invalid", trace.snapshot().invalidFrames == 1)
        trace.start(sessionID: id, windowID: 5)
        frame.rect[2] = Double.nan
        _ = trace.record(sessionID: id, frame: frame)
        check("frame nonfinite metadata is invalid and JSON safe", trace.snapshot().invalidFrames == 1 && (try? JSONEncoder().encode(trace.snapshot())) != nil)
        let next = UUID()
        trace.start(sessionID: next, windowID: 5)
        check("frame old callback cannot acquire current session", !trace.record(sessionID: id, frame: frame) && trace.snapshot().rejectedContexts == 1)
        for status in [AnswerFrameStatus.blank, .suspended, .stopped] {
            trace.start(sessionID: id, windowID: 5)
            idle.status = status
            _ = trace.record(sessionID: id, frame: idle)
            check("frame unavailable display is an explicit failure", trace.snapshot().invalidFrames == 1)
        }
        trace.start(sessionID: id, windowID: 5)
        frame.rect = [-1,0,801,600]; frame.displayNs = 3_000
        _ = trace.record(sessionID: id, frame: frame)
        check("frame clipped rectangle cannot qualify", trace.snapshot().invalidFrames == 1)
        trace.start(sessionID: next, windowID: 5)
        check("frame old encoder error cannot charge new session", !trace.noteWriteError(sessionID: id) && trace.snapshot().writeErrors == 0)
        check("frame old cap event cannot charge new session", !trace.noteTruncated(sessionID: id) && !trace.snapshot().truncated)
    }
}
