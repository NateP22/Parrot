import Foundation

enum AudioTraceChecks {
    static func run(_ check: (Bool, String) -> Void) {
        let stamp = CapturedAudioClockStamp(backend: .tap, hostStartNs: 1_000_000_000,
            hostTicks: 24_000_000, sourceFrames: 480, sourceRate: 48_000, sourceSampleTime: 0)
        let disabled = AnswerAudioTraceRecorder(enabled: false)
        disabled.start(sessionID: UUID())
        check(disabled.snapshot().sessionID == nil, "audioTrace disabled has no session")
        let journal = AnswerAudioTraceRecorder(enabled: true, spanLimit: 2)
        let first = UUID()
        journal.start(sessionID: first)
        check(journal.record(sessionID: first, source: .them, stamp: stamp, outputStart: 80,
            paddingBefore: 80, outputFrames: 160, outputRate: 16_000, callbackNs: 1_500_000_000),
            "audioTrace records exact raw clock and emitted offsets")
        let row = journal.snapshot().spans.first
        check(row?.hostStartNs == 1_000_000_000 && row?.callbackNs == 1_500_000_000,
              "audioTrace late delivery never shifts capture clock")
        check(row?.outputStart == 80 && row?.paddingBefore == 80 && row?.outputFrames == 160,
              "audioTrace padding has no invented host anchor")
        check(row?.rawDurationUpperNs == 10_000_000 && row?.requiresCalibration == true,
              "audioTrace raw duration is integer and conversion is uncalibrated")
        check(!journal.snapshot().nativeAcceptance, "audioTrace never grants native acceptance")
        let secondStamp = CapturedAudioClockStamp(backend: .tap, hostStartNs: 1_010_000_000,
            hostTicks: 24_240_000, sourceFrames: 480, sourceRate: 48_000, sourceSampleTime: 480)
        _ = journal.record(sessionID: first, source: .them, stamp: secondStamp, outputStart: 240,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 1_600_000_000)
        check(journal.snapshot().invalidSpans == 0, "audioTrace continuous capture accepts delayed callbacks")
        _ = journal.record(sessionID: first, source: .them, stamp: secondStamp, outputStart: 400,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 1_700_000_000)
        check(journal.snapshot().truncated && journal.snapshot().spans.count == 2,
              "audioTrace cap is sticky and never evicts earlier spans")
        let next = UUID()
        journal.start(sessionID: next)
        check(!journal.record(sessionID: first, source: .them, stamp: stamp, outputStart: 0,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 1_500_000_000),
            "audioTrace old callback cannot acquire new session")
        check(journal.snapshot().rejectedContexts == 1 && journal.snapshot().spans.isEmpty,
              "audioTrace stale callback remains visible as invalid evidence")
        for rate in [0.0, Double.nan, Double.infinity, 44_099.5] {
            let bad = CapturedAudioClockStamp(backend: .microphone, hostStartNs: nil,
                hostTicks: nil, sourceFrames: 480, sourceRate: rate, sourceSampleTime: nil)
            journal.start(sessionID: next)
            _ = journal.record(sessionID: next, source: .me, stamp: bad, outputStart: 0,
                paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 1)
            check(journal.snapshot().invalidSpans == 1, "audioTrace missing clock/invalid rate fails closed")
            check((try? JSONEncoder().encode(journal.snapshot())) != nil,
                  "audioTrace nonfinite raw metadata cannot corrupt journal encoding")
        }
        journal.start(sessionID: next)
        _ = journal.record(sessionID: next, source: .them, stamp: stamp, outputStart: 0,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_000_000_000)
        _ = journal.record(sessionID: next, source: .them, stamp: stamp, outputStart: 160,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_100_000_000)
        check(journal.snapshot().invalidSpans == 1, "audioTrace repeated or out-of-order capture is invalid")
        journal.start(sessionID: next)
        _ = journal.record(sessionID: next, source: .them, stamp: stamp, outputStart: UInt64.max,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_000_000_000)
        check(journal.snapshot().invalidSpans == 1, "audioTrace output range overflow rejected")
        journal.start(sessionID: next)
        _ = journal.record(sessionID: next, source: .them, stamp: stamp, outputStart: 0,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_000_000_000)
        let overlap = CapturedAudioClockStamp(backend: .tap, hostStartNs: 1_005_000_000,
            hostTicks: nil, sourceFrames: 480, sourceRate: 48_000, sourceSampleTime: 480)
        _ = journal.record(sessionID: next, source: .them, stamp: overlap, outputStart: 160,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_100_000_000)
        check(journal.snapshot().invalidSpans == 1, "audioTrace partial raw overlap cannot qualify")
        let noSampleFlag = CapturedAudioClockStamp(backend: .tap, hostStartNs: 1_000_000_000,
            hostTicks: 24_000_000, sourceFrames: 480, sourceRate: 48_000, sourceSampleTime: nil)
        journal.start(sessionID: next)
        _ = journal.record(sessionID: next, source: .them, stamp: noSampleFlag, outputStart: 0,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_000_000_000)
        check(journal.snapshot().invalidSpans == 1, "audioTrace missing tap sample-time flag is invalid")
        _ = journal.finish()
        check(!journal.record(sessionID: next, source: .them, stamp: stamp, outputStart: 160,
            paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_100_000_000),
            "audioTrace Stop freezes the prior capture epoch")
        for value in [Double.nan, Double.infinity] {
            journal.start(sessionID: next)
            let badSample = CapturedAudioClockStamp(backend: .screenCapture, hostStartNs: 1_000_000_000,
                hostTicks: nil, sourceFrames: 480, sourceRate: 48_000, sourceSampleTime: value)
            _ = journal.record(sessionID: next, source: .them, stamp: badSample, outputStart: 0,
                paddingBefore: 0, outputFrames: 160, outputRate: 16_000, callbackNs: 2_000_000_000)
            check(journal.snapshot().invalidSpans == 1, "audioTrace corrupt sample clock never becomes clean nil")
        }
        var writes = 0
        let writeJournal = AnswerAudioTraceRecorder(enabled: true, outputRoot: URL(fileURLWithPath: "/unused"),
            writer: { _, _ in writes += 1 })
        writeJournal.start(sessionID: next)
        _ = writeJournal.finish()
        _ = writeJournal.finish()
        check(writes == 1, "audioTrace repeated Stop writes the frozen journal only once")
    }
}
