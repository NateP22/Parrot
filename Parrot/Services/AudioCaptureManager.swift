import AVFoundation
import ScreenCaptureKit
import CoreAudio
import Combine
import os

/// Captures system audio via ScreenCaptureKit and microphone via AVAudioEngine.
/// Provides mixed PCM audio for transcription and saves separate tracks to disk.
@Observable
final class AudioCaptureManager: NSObject {
    private var stream: SCStream?
    @ObservationIgnored private var traceCaptureEpoch: UUID?
    @ObservationIgnored private let traceStreamLock = NSLock()
    @ObservationIgnored private var traceStreamEpochs: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private let traceCallbackLock = NSLock()
    private var audioEngine: AVAudioEngine?
    // Write uncompressed PCM (.caf) via AVAudioFile rather than AAC/.m4a via
    // AVAssetWriter: on recent macOS the AAC encoder fails to initialize
    // (AudioCodecInitialize failed / -12651), producing silent 0-byte files.
    // PCM has no codec to fail. Each file is written only from its own serial
    // queue, off the audio render thread.
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    /// Set true before stopCapture's sync barriers. A straggler write block that
    /// was enqueued after the barriers must not lazily recreate an AVAudioFile on
    /// the finished URL — AVAudioFile(forWriting:) truncates, destroying the
    /// recording, and the stale file object would hijack the NEXT recording's
    /// audio. Plain Bool across threads, same accepted pattern as `isCapturing`.
    private var filesClosed = true
    private let systemWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.system")
    private let micWriteQueue = DispatchQueue(label: "com.uygar.parrot.audio.mic")
    /// Acoustic echo canceller, created per recording when enabled. Removes the
    /// speaker bleed from the mic using the system audio as the reference. nil =
    /// disabled (mic passes through untouched).
    private var echoCanceller: EchoCanceller?
    /// `PARROT_AEC_DUMP=1` only: what the canceller was fed, for `--aec-replay`.
    private var aecDump: AECDump?

    /// Which system-audio engine is live. Prefer authorized ScreenCaptureKit
    /// and use it for the macOS version with a reproduced tap-startup hang.
    enum CaptureBackend: String { case none, tap, sck }
    /// Native GUI capture on 26.5.1 blocks in AudioDeviceStart even after the
    /// audio-only grant. Keep this workaround bounded to the reproduced OS;
    /// PermissionFlow requests ScreenCaptureKit's matching grant there.
    static func requiresScreenCaptureKit(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion == 26 && version.minorVersion == 5 && version.patchVersion == 1
    }

    static func shouldPreferScreenCaptureKit(
        screenCaptureGranted: Bool, forceSCK: Bool,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        screenCaptureGranted || forceSCK || requiresScreenCaptureKit(on: version)
    }
    @ObservationIgnored private(set) var captureBackend: CaptureBackend = .none
    /// The live SystemAudioTap on macOS 15+. Typed AnyObject because
    /// @available(macOS 15) types can't be stored properties at target 14.
    private var processTap: AnyObject?
    /// System audio the tap skipped in the last recording (late callbacks).
    @ObservationIgnored private(set) var systemLostSeconds: Double = 0
    /// True once the tap delivered any nonzero sample this recording. An
    /// unauthorized tap "works" but produces exact zeros forever (measured, no
    /// error/status API exists), so first real audio is the only proof of the
    /// "System Audio Recording Only" grant — it also feeds the silence rescue.
    @ObservationIgnored private var tapEverHadSignal = false

    /// The recording clock both tracks are placed on (monotonic seconds, set as
    /// capture goes live), and each stream's frames handed to its file and to
    /// transcription so far. One counter per stream: each is only touched on
    /// that stream's capture thread.
    @ObservationIgnored private var captureOrigin: TimeInterval = 0
    @ObservationIgnored private var systemFramesOut = 0
    @ObservationIgnored private var micFramesOut = 0
    @ObservationIgnored private var lastAlignmentLogAt = Date.distantPast

    /// Throttle timestamps for pushing audio levels to the UI — the waveform needs
    /// only ~10 updates/sec, not one per ~20 ms audio buffer per stream.
    @ObservationIgnored private var lastSystemLevelAt = Date.distantPast
    @ObservationIgnored private var lastMicLevelAt = Date.distantPast

    /// Opt-in diagnostics for the "transcription dies when I join a call" bug:
    /// one AUDIODBG log line per stream every 5 s with raw (pre-AEC) mic level,
    /// cleaned (post-AEC) mic level, all-zero buffer counts, and SCK delivery
    /// rate — enough to tell OS-delivered silence apart from AEC suppression.
    /// Enable: PARROT_AUDIO_DEBUG=1 env, or `defaults write ... audioDebug -bool YES`.
    /// #98: save the canceller's raw mic + paired reference for `--aec-replay`.
    /// Raw call audio, so env only: `open -a Parrot --env PARROT_AEC_DUMP=1`.
    static let aecDumpEnabled = ProcessInfo.processInfo.environment["PARROT_AEC_DUMP"] != nil
    static let audioDebugEnabled =
        ProcessInfo.processInfo.environment["PARROT_AUDIO_DEBUG"] != nil
        || UserDefaults.standard.bool(forKey: "audioDebug")
    @ObservationIgnored private var dbgMic = DebugAccumulator(label: "mic")
    @ObservationIgnored private var dbgSck = DebugAccumulator(label: "sck")

    /// Capture events and AUDIODBG lines go through os_log with explicit public
    /// privacy: NSLog from the sandboxed app is redacted to "<private>" in
    /// `log show`, which silently made the field diagnostics uncollectable.
    static let oslog = Logger(subsystem: "com.uygar.parrot", category: "capture")

    /// Accumulates levels between 5 s log flushes. Each instance is only touched
    /// from its own stream's callback thread.
    struct DebugAccumulator {
        let label: String
        var rawSum: Float = 0; var rawN = 0
        var cleanSum: Float = 0; var cleanN = 0
        var buffers = 0; var zeroBuffers = 0
        var lastFlush = Date()

        init(label: String) { self.label = label }

        mutating func add(raw: Float, clean: Float?, refBacklog: Int?, extra: String = "") {
            rawSum += raw; rawN += 1
            if let clean { cleanSum += clean; cleanN += 1 }
            buffers += 1
            if raw == 0 { zeroBuffers += 1 }
            let now = Date()
            guard now.timeIntervalSince(lastFlush) >= 5 else { return }
            let rawAvg = rawN > 0 ? rawSum / Float(rawN) : 0
            let cleanAvg = cleanN > 0 ? cleanSum / Float(cleanN) : 0
            let cleanPart = clean != nil ? String(format: " clean=%.5f", cleanAvg) : ""
            let refPart = refBacklog.map { " refq=\($0)" } ?? ""
            let line = String(format: "AUDIODBG %@ raw=%.5f%@ bufs=%d zerobufs=%d%@%@",
                              label, rawAvg, cleanPart, buffers, zeroBuffers, refPart, extra)
            AudioCaptureManager.oslog.log("\(line, privacy: .public)")
            rawSum = 0; rawN = 0; cleanSum = 0; cleanN = 0
            buffers = 0; zeroBuffers = 0
            lastFlush = now
        }
    }

    /// Detects the OS silently cutting the mic feed (issue #12): a call app that
    /// grabs the microphone (Safari/Zoom voice processing) makes CoreAudio deliver
    /// exact digital zeros to every other client — the engine keeps running and no
    /// configuration-change notification fires, so the samples are the only tell.
    /// A real mic in a silent room still carries dither noise; a sustained run of
    /// *exact* zeros is always artificial. Pure logic so --profile-test can drive
    /// it with a fake clock.
    struct MicSignalWatchdog {
        enum Verdict: Equatable { case ok, lost, stillLost, recovered }
        /// Long enough to skip transient device glitches, short enough that the
        /// warning appears before the user wonders where their words went.
        static let lostAfter: TimeInterval = 2
        private var zeroRunStartedAt: Date?
        private(set) var isLost = false

        mutating func observe(meanAbs: Float, at now: Date) -> Verdict {
            guard meanAbs == 0 else {
                zeroRunStartedAt = nil
                if isLost { isLost = false; return .recovered }
                return .ok
            }
            let start = zeroRunStartedAt ?? now
            zeroRunStartedAt = start
            if isLost { return .stillLost }
            guard now.timeIntervalSince(start) >= Self.lostAfter else { return .ok }
            isLost = true
            return .lost
        }
    }

    /// True while the OS is delivering exact digital zeros on the mic — another
    /// app (typically a call) holds the microphone. Drives the device-bar warning
    /// and the periodic reclaim attempts. Issue #12.
    private(set) var micSignalLost = false
    /// Tap-callback thread only, like the debug accumulators.
    @ObservationIgnored private var micWatchdog = MicSignalWatchdog()
    /// Main thread only — collapses the per-buffer verdicts into one pending retry.
    @ObservationIgnored private var micRecoveryScheduled = false

    private(set) var isCapturing = false
    private(set) var systemAudioURL: URL?
    private(set) var micAudioURL: URL?
    private(set) var audioLevel: Float = 0
    /// Live mic input level (separate from system audio) so the UI can show
    /// whether the user's own voice is actually being picked up.
    private(set) var micLevel: Float = 0
    /// Loudest mic buffer seen this recording. Separates "the mic delivers
    /// nothing" (dead/denied → micSeemsDead) from "the mic delivers a whisper"
    /// (input volume set very low → micVeryQuiet).
    private(set) var micPeakLevel: Float = 0
    /// Whether the mic stream is actually capturing (false = system audio only).
    private(set) var micActive = false
    private(set) var inputDeviceName = ""
    private(set) var outputDeviceName = ""
    /// Capture-start time, or the last moment the mic carried real signal. While the
    /// mic has never been heard it stays at capture start, so it doubles as "how long
    /// the mic has been silent since recording began".
    private(set) var lastMicSignalAt = Date.distantPast

    /// True once the mic has produced any real signal this recording. A user who is
    /// merely listening (normal while the other side talks) just hasn't spoken yet —
    /// that is not a dead mic — so once we've heard signal we never warn.
    private(set) var micEverHadSignal = false

    /// True when echo cancellation is enabled but the system-audio reference never
    /// arrives in the expected format — the AEC is then a silent no-op and the
    /// far end's voice can transcribe as "Me". Shown in the live device bar.
    private(set) var echoCancellerStarved = false

    /// True only when the mic has been on for a while but has never produced any
    /// signal — a genuinely dead, muted, or misrouted mic. We key off "never heard"
    /// rather than recent silence, because in a call the user is routinely silent for
    /// far longer than a few seconds while the other side is speaking.
    var micSeemsDead: Bool {
        isCapturing && micActive && !micMuted && !micEverHadSignal && micPeakLevel < 0.0008
            && Date().timeIntervalSince(lastMicSignalAt) > 15
    }

    /// True when the mic is alive but everything it has heard sits far below
    /// speech level — almost always the input volume slider set very low (a
    /// real session at 49% volume measured speech at ~0.0014 mean-abs,
    /// 2026-08-04). Transcription survives this (adaptive floor + decode
    /// normalization), but accuracy is better with real signal, so the device
    /// bar nudges the user. One healthy-loudness buffer flips
    /// `micEverHadSignal` and clears the hint for the session; mutually
    /// exclusive with `micSeemsDead` via the same peak split.
    var micVeryQuiet: Bool {
        isCapturing && micActive && !micMuted && !micEverHadSignal && micPeakLevel >= 0.0008
            && Date().timeIntervalSince(lastMicSignalAt) > 15
    }

    /// "Mute me" (#96): Zoom's mute never reaches Parrot, which opens the mic
    /// itself. The mic keeps running, so the echo canceller and the recording
    /// clock stay in step, but your side records silence. Set on main, read on
    /// the mic tap thread, like `isCapturing`.
    private(set) var micMuted = false

    func setMicMuted(_ muted: Bool) {
        micMuted = muted
        if !muted { lastMicSignalAt = Date() }  // a fresh 15 s before "not hearing you"
    }

    /// Silence of the same length while muted. After the watchdog, which reads
    /// the raw mic: zeros there would look like another app grabbing it.
    static func micOut(_ cleaned: [Float], muted: Bool) -> [Float] {
        muted ? [Float](repeating: 0, count: cleaned.count) : cleaned
    }

    /// Called with PCM audio buffers suitable for WhisperKit, tagged with which
    /// stream they came from (mic = the user, system = everyone else).
    var onAudioBuffer: ((AVAudioPCMBuffer, AudioSource) -> Void)?

    /// Observer for AVAudioEngineConfigurationChange on the current engine.
    private var micRestartObserver: NSObjectProtocol?

    private let sampleRate: Double = 16000
    private let channels: UInt32 = 1

    /// Dev-harness only (--help-shots): make the device bar look mid-call
    /// without touching any real audio device.
    @MainActor
    func seedForSnapshot(input: String, output: String, micLevel: Float, systemLevel: Float) {
        inputDeviceName = input
        outputDeviceName = output
        micActive = true
        isCapturing = true
        micEverHadSignal = true
        lastMicSignalAt = Date()
        self.micLevel = micLevel
        audioLevel = systemLevel
    }

    // MARK: - Start Capture

    /// @MainActor for the same reason as TranscriptionEngine.loadModel: these
    /// lifecycle funcs mutate UI-observed state (`isCapturing`, `micActive`,
    /// device names…), and a nonisolated async func runs on the global executor
    /// — off-main observation mutations race SwiftUI/SwiftData invalidation.
    /// The tap/stream hot path is untouched: it stays off-main and already hops
    /// via DispatchQueue.main.async for every observable write.
    @MainActor
    func startCapture() async throws {
        guard QASetupLaunch.permitsMeetingWork else { throw QASetupLaunch.Unavailable.recording }
        traceCaptureEpoch = AnswerTraceRecorder.shared.sessionID
        AnswerAudioTraceRecorder.shared.start(sessionID: traceCaptureEpoch)
        let storageDir = Self.storageDirectory()
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")

        systemAudioURL = storageDir.appendingPathComponent("system_\(timestamp).caf")
        micAudioURL = storageDir.appendingPathComponent("mic_\(timestamp).caf")

        inputDeviceName = Self.defaultDeviceName(input: true)
        outputDeviceName = Self.defaultDeviceName(input: false)
        NSLog("Parrot: starting capture — input: \(inputDeviceName), output: \(outputDeviceName)")

        // Echo cancellation on by default (defeats speaker bleed without headphones).
        let aecEnabled = UserDefaults.standard.object(forKey: "echoCancellationEnabled") as? Bool ?? true
        echoCanceller = aecEnabled ? EchoCanceller() : nil
        aecDump = nil
        if Self.aecDumpEnabled, let echoCanceller, let dump = AECDump(dir: storageDir, timestamp: timestamp) {
            aecDump = dump
            echoCanceller.onPairs = { dump.write(mic: $0, ref: $1) }
            Self.oslog.log("aec dump: aec-mic_\(timestamp, privacy: .public).caf + aec-ref_\(timestamp, privacy: .public).caf")
        }

        // Reset the mic watchdog before any tap can fire.
        micWatchdog = MicSignalWatchdog()
        lastAlignmentLogAt = .distantPast
        micSignalLost = false
        micRecoveryScheduled = false
        tapEverHadSignal = false

        filesClosed = false  // fresh URLs above; queues are idle, so no race

        let t0 = ProcessInfo.processInfo.systemUptime
        try await startSystemAudioCapture()
        let t1 = ProcessInfo.processInfo.systemUptime
        dbgSck = DebugAccumulator(label: captureBackend.rawValue)

        // The microphone is optional. System audio ("Them") is the core capture;
        // a missing or denied mic must NOT abort the whole recording. If mic setup
        // fails we just don't get the user's own voice ("Me") and carry on.
        do {
            try startMicCapture()
            micActive = true
        } catch {
            micActive = false
            micAudioURL = nil
            NSLog("Parrot: microphone unavailable, recording system audio only — \(error.localizedDescription)")
        }

        lastMicSignalAt = Date()  // capture start; the "dead mic" warning waits on this
        micMuted = false
        micEverHadSignal = false
        micPeakLevel = 0
        echoCancellerStarved = false
        systemFramesOut = 0
        micFramesOut = 0
        captureOrigin = ProcessInfo.processInfo.systemUptime
        isCapturing = true
        Self.oslog.log("capture live — \(self.captureBackend.rawValue, privacy: .public) up in \(Int((t1 - t0) * 1000), privacy: .public) ms, mic in \(Int((self.captureOrigin - t1) * 1000), privacy: .public) ms")
    }

    // MARK: - Stop Capture

    @MainActor
    func stopCapture() async {
        isCapturing = false
        micActive = false
        micEverHadSignal = false
        micSignalLost = false
        micMuted = false
        audioLevel = 0
        micLevel = 0
        micPeakLevel = 0
        echoCanceller = nil

        // Stop system audio stream (whichever backend is live)
        if #available(macOS 15.0, *), let tap = processTap as? SystemAudioTap {
            tap.stop()
            systemLostSeconds = tap.lostSeconds
        }
        processTap = nil
        if let stream {
            try? await stream.stopCapture()
            traceStreamLock.withLock { traceStreamEpochs.removeValue(forKey: ObjectIdentifier(stream)) }
            self.stream = nil
        }
        captureBackend = .none

        // Stop mic engine
        if let micRestartObserver { NotificationCenter.default.removeObserver(micRestartObserver) }
        micRestartObserver = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        // QA callbacks recheck isCapturing under this same lock. A callback
        // already processing drains here; a queued late callback emits nothing.
        if AnswerAudioTraceRecorder.shared.isEnabled {
            traceCallbackLock.lock(); traceCallbackLock.unlock()
        }

        // Flush queued writes, then close the files. AVAudioFile finalizes the
        // .caf header when it deallocates; the sync barrier guarantees every
        // pending write has landed first. filesClosed goes up BEFORE the
        // barriers so any write block enqueued after them no-ops instead of
        // recreating (= truncating) the finished file.
        filesClosed = true
        systemWriteQueue.sync { systemAudioFile = nil }
        micWriteQueue.sync { micAudioFile = nil }
        aecDump?.close()
        aecDump = nil

        if let url = systemAudioURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            NSLog("Parrot: system audio file finalized — \(size) bytes")
        }
        _ = AnswerAudioTraceRecorder.shared.finish()
    }

    // MARK: - System Audio

    /// Use authorized or compatibility-required ScreenCaptureKit first;
    /// otherwise use the macOS 15+ audio-only tap. Both feed handleSystemAudio
    /// with identical 16 kHz mono buffers, so everything downstream is unaware.
    @MainActor
    private func startSystemAudioCapture() async throws {
        // This remains useful for field debugging; granted SCK permission also
        // selects the tested backend without needing a persistent defaults flag.
        let preferSCK = Self.shouldPreferScreenCaptureKit(
            screenCaptureGranted: CGPreflightScreenCaptureAccess(),
            forceSCK: UserDefaults.standard.bool(forKey: "forceSCKCapture")
        )
        if #available(macOS 15.0, *), !preferSCK {
            do {
                try startTapCapture()
                return
            } catch {
                NSLog("Parrot: process-tap capture unavailable (\(error.localizedDescription)) — falling back to ScreenCaptureKit")
            }
            do {
                try await startSCKCapture()
            } catch {
                // Neither path came up. Report in the language of the new
                // permission, not the legacy Screen Recording one.
                throw CaptureError.systemAudioUnavailable
            }
            return
        }
        try await startSCKCapture()
    }

    @available(macOS 15.0, *)
    @MainActor
    private func startTapCapture() throws {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
        let tap = SystemAudioTap(targetFormat: targetFormat)
        let traceEpoch = traceCaptureEpoch
        tap.onBuffer = { [weak self] buffer, stamp in
            guard let self, self.isCapturing else { return }
            self.handleSystemAudio(buffer, traceStamp: stamp, traceEpoch: traceEpoch)
        }
        try tap.start()
        processTap = tap
        captureBackend = .tap
        scheduleTapSilenceRescue()
    }

    /// An unauthorized tap "succeeds" and delivers silence forever, with no way
    /// to ask TCC (measured). So while the tap stays all-zeros, every 15 s:
    /// swap to ScreenCaptureKit if Screen Recording IS granted (typical for
    /// users upgrading from the SCK era) — same buffers, same files, nothing
    /// downstream notices; otherwise recreate the tap, because a "System
    /// Audio" grant the user clicks mid-recording may only take effect on a
    /// tap created after it. Either way a recording converges to real audio
    /// within ~15 s of the user clicking Allow, and a false trigger (call
    /// genuinely silent for 15 s) is harmless for the same reason.
    @available(macOS 15.0, *)
    private func scheduleTapSilenceRescue() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.isCapturing, self.captureBackend == .tap, !self.tapEverHadSignal,
                  let tap = self.processTap as? SystemAudioTap else { return }
            tap.stop()
            self.processTap = nil
            if CGPreflightScreenCaptureAccess() {
                Self.oslog.log("system tap silent for 15 s — swapping to the ScreenCaptureKit backend")
                do {
                    try await self.startSCKCapture()
                } catch {
                    Self.oslog.error("SCK rescue failed — \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Self.oslog.log("system tap silent for 15 s — recreating it to pick up a fresh System Audio grant")
                try? self.startTapCapture()  // re-arms this rescue
            }
        }
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSCKCapture() async throws {
        let t0 = ProcessInfo.processInfo.systemUptime
        // Pre-check screen capture permission
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw CaptureError.screenRecordingDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channels)
        // We only want audio, minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // The system audio file is created lazily from the first buffer's format
        // (see the SCStreamOutput handler), so it always matches what we write.

        let t1 = ProcessInfo.processInfo.systemUptime
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        if let epoch = traceCaptureEpoch {
            traceStreamLock.withLock { traceStreamEpochs[ObjectIdentifier(stream)] = epoch }
        }
        do { try await stream.startCapture() }
        catch {
            traceStreamLock.withLock { traceStreamEpochs.removeValue(forKey: ObjectIdentifier(stream)) }
            throw error
        }
        self.stream = stream
        captureBackend = .sck
        let now = ProcessInfo.processInfo.systemUptime
        Self.oslog.log("SCK up in \(Int((now - t0) * 1000), privacy: .public) ms (shareable content \(Int((t1 - t0) * 1000), privacy: .public), stream start \(Int((now - t1) * 1000), privacy: .public))")
    }

    // MARK: - System audio ingest (shared by both backends)

    /// Everything downstream of capture: persist "Them" to disk, prove the tap
    /// grant, feed the echo-canceller reference, update the level, and hand the
    /// buffer to transcription. Buffers arrive as 16 kHz mono Float32 from
    /// either backend; runs on that backend's own audio queue.
    private func handleSystemAudio(_ pcmBuffer: AVAudioPCMBuffer,
                                   traceStamp: CapturedAudioClockStamp? = nil, traceEpoch: UUID? = nil) {
        let tracing = AnswerAudioTraceRecorder.shared.isEnabled
        if tracing { traceCallbackLock.lock() }
        defer { if tracing { traceCallbackLock.unlock() } }
        if tracing && !isCapturing { return }
        // First nonzero sample through the tap is the only readable proof of
        // the System Audio TCC grant — persist it for PermissionFlow.
        if captureBackend == .tap, !tapEverHadSignal,
           Self.meanAbs(Self.floats(from: pcmBuffer)) > 0 {
            tapEverHadSignal = true
            UserDefaults.standard.set(true, forKey: PermissionFlow.tapProvenKey)
        }

        if Self.audioDebugEnabled {
            dbgSck.add(
                raw: Self.meanAbs(Self.floats(from: pcmBuffer)),
                clean: nil,
                refBacklog: nil,
                extra: String(format: " fmt=%.0fHz x%dch",
                              pcmBuffer.format.sampleRate, pcmBuffer.format.channelCount))
        }

        // Feed the same audio to the echo canceller as the far-end reference, so it
        // can subtract this from the mic. Only when it's the expected 16 kHz mono.
        if pcmBuffer.format.sampleRate == sampleRate, pcmBuffer.format.channelCount == channels {
            echoCanceller?.pushReference(Self.floats(from: pcmBuffer))
        } else if echoCanceller != nil, !echoCancellerStarved {
            // Without a reference the AEC is silently a no-op and speaker bleed
            // transcribes as "Me" — surface it once instead of hiding it.
            NSLog("Parrot: echo canceller starved — system audio is \(pcmBuffer.format.sampleRate) Hz ×\(pcmBuffer.format.channelCount)ch, expected \(sampleRate) Hz mono")
            DispatchQueue.main.async { self.echoCancellerStarved = true }
        }

        // Update audio level
        updateAudioLevel(buffer: pcmBuffer)

        // Persist everyone else's voice ("Them") and transcribe it
        emit(pcmBuffer, to: .system, traceStamp: traceStamp, traceEpoch: traceEpoch)
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        // AVAudioEngine can advertise a plausible output format even when
        // this Mac has no input hardware. Do not create an input engine then:
        // installTap can raise an Objective-C exception Swift cannot catch.
        guard let inputDeviceID = Self.defaultDeviceID(input: true),
              MicrophoneInputFormat.hasInputChannels(Self.inputChannelCounts(deviceID: inputDeviceID)) else {
            Self.oslog.log("microphone unavailable — default input has no input streams")
            throw CaptureError.noMicrophone
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // NOTE: we previously enabled setVoiceProcessingEnabled(true) for acoustic
        // echo cancellation, but on this hardware it cancelled ALL mic input (the
        // user's own voice was lost — every recording came back with only "Them").
        // Reverted. Echo (mic picking up the speakers) is avoided by using
        // headphones; a safer AEC approach can be revisited and tested later.

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Apple requires checking the INPUT (hardware) format. The output
        // alone can remain 44.1 kHz stereo with no usable microphone. This
        // real-device path has no voice processing/manual format conversion.
        guard MicrophoneInputFormat.isUsable(
            hardwareRate: hardwareFormat.sampleRate, hardwareChannels: hardwareFormat.channelCount,
            tapRate: inputFormat.sampleRate, tapChannels: inputFormat.channelCount) else {
            Self.oslog.log("microphone unavailable — input hardware/tap formats are invalid or mismatched")
            throw CaptureError.noMicrophone
        }

        // The mic file is created lazily from the converted (16 kHz mono) format.

        // Convert mic audio to our target format for WhisperKit
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.noMicrophone
        }

        let traceEpoch = traceCaptureEpoch
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, audioTime in
            guard let self, self.isCapturing else { return }
            let tracing = AnswerAudioTraceRecorder.shared.isEnabled
            if tracing { self.traceCallbackLock.lock() }
            defer { if tracing { self.traceCallbackLock.unlock() } }
            if tracing && !self.isCapturing { return }

            // Convert to target format
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return
            }

            var error: NSError?
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                // Contract: the converter may call this more than once per
                // convert() during rate conversion — handing it the same buffer
                // again duplicates ~20 ms of mic audio (stutter in "Me").
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                // Echo-cancel the mic using the system audio as reference. With AEC
                // off, this returns the mic unchanged. With it on, it returns cleaned
                // 10 ms frames (possibly empty until a frame fills) — fail-safe.
                let micFloats = Self.floats(from: convertedBuffer)
                // Watch the RAW mic, pre-AEC: the canceller legitimately emits
                // empty/quiet frames, but only the OS produces exact zeros.
                let verdict = self.micWatchdog.observe(meanAbs: Self.meanAbs(micFloats), at: Date())
                if verdict != .ok { self.handleMicWatchdog(verdict) }
                let cleaned = Self.micOut(self.echoCanceller?.process(mic: micFloats) ?? micFloats,
                                          muted: self.micMuted)
                // #98: the canceller only removes echo that lands within its
                // 128 ms tail (2048 samples). A backlog past that, or frames
                // fed silence, means it's blind and speaker echo reaches Me.
                // In step isn't enough: it also says how much echo it took out
                // while they talked, and the mic slider call apps can move.
                // Same line start, so the grep in the #98 thread still finds it.
                if let aec = self.echoCanceller, Date().timeIntervalSince(self.lastAlignmentLogAt) >= 60 {
                    self.lastAlignmentLogAt = Date()
                    let echo = aec.takeStats().map {
                        String(format: "while they talk (%d frames): removed %.0f dB, filter alone %.0f dB, mic hears speakers at %.0f dB",
                               $0.frames, $0.removed, $0.filterAlone, $0.hears)
                    } ?? "while they talk: -"
                    let volume = Self.inputVolume().map { "\(Int(($0 * 100).rounded()))%" } ?? "-"
                    Self.oslog.log("echo canceller alignment: backlog \(aec.referenceBacklog, privacy: .public) samples, starved \(aec.starvedFrames, privacy: .public) frames; \(echo, privacy: .public); mic volume \(volume, privacy: .public)")
                }
                if Self.audioDebugEnabled {
                    self.dbgMic.add(
                        raw: Self.meanAbs(micFloats),
                        clean: cleaned.isEmpty ? nil : Self.meanAbs(cleaned),
                        refBacklog: self.echoCanceller?.referenceBacklog,
                        extra: String(format: " devfmt=%.0fHz", inputFormat.sampleRate))
                }
                guard !cleaned.isEmpty,
                      let cleanedBuffer = Self.makeBuffer(cleaned, format: targetFormat) else { return }

                // Persist the user's voice ("Me") as 16 kHz mono PCM and transcribe it
                var stamp: CapturedAudioClockStamp?
                if AnswerAudioTraceRecorder.shared.isEnabled {
                    let ticks = audioTime.isHostTimeValid ? audioTime.hostTime : nil
                    stamp = CapturedAudioClockStamp(backend: .microphone,
                        hostStartNs: ticks.flatMap { AnswerTraceClock.nanoseconds(ticks: $0) }, hostTicks: ticks,
                        sourceFrames: buffer.frameLength, sourceRate: inputFormat.sampleRate,
                        sourceSampleTime: audioTime.isSampleTimeValid ? Double(audioTime.sampleTime) : nil)
                }
                self.emit(cleanedBuffer, to: .mic, traceStamp: stamp, traceEpoch: traceEpoch)

                // Update the mic level so the UI can show the user's voice landing.
                self.updateAudioLevel(buffer: cleanedBuffer, isMic: true)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        // AVAudioEngine stops itself when the input device changes or vanishes
        // (dead AirPods, a manual input switch in System Settings) and never
        // comes back on its own — a 1-hour call once lost its mic at minute 44
        // this way. Rebuild the tap on whatever the new default input is.
        if let micRestartObserver { NotificationCenter.default.removeObserver(micRestartObserver) }
        micRestartObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartMicCapture()
        }
    }

    /// Tear down the stopped engine and rebuild the mic tap on the current
    /// default input. Retries for a while — a Bluetooth handoff takes seconds
    /// to settle, and mid-transition there may briefly be no input device.
    private func restartMicCapture(attempt: Int = 0) {
        guard isCapturing else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        echoCanceller?.micRestarted()
        do {
            try startMicCapture()
            micActive = true
            inputDeviceName = Self.defaultDeviceName(input: true)
            // The dead gap is padded by emit() on the first new buffer, so the
            // file and the "Me" transcript clock both skip it.
            NSLog("Parrot: mic restarted after device change — input: \(inputDeviceName)")
        } catch {
            micActive = false
            guard attempt < 10 else {
                NSLog("Parrot: mic restart gave up after \(attempt) retries — \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartMicCapture(attempt: attempt + 1)
            }
        }
    }

    /// Tap thread → main. Flips the observable flag and, while the mic stays
    /// zeroed, periodically rebuilds the input engine: if the app that held the
    /// mic is gone, the rebuild reclaims it instantly; if not, the fresh tap
    /// keeps reporting zeros and we simply try again. Either way the state is
    /// visible instead of the recording dying in silence.
    private func handleMicWatchdog(_ verdict: MicSignalWatchdog.Verdict) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch verdict {
            case .lost:
                self.micSignalLost = true
                Self.oslog.warning("mic feed went to digital zeros — another app likely holds the microphone")
                self.scheduleMicReclaim()
            case .stillLost:
                self.scheduleMicReclaim()
            case .recovered:
                self.micSignalLost = false
                Self.oslog.log("mic feed recovered")
            case .ok:
                break
            }
        }
    }

    /// Main thread. One pending reclaim at a time, 4 s apart — a rebuild is
    /// cheap but not free, and the common case (call app still holds the mic)
    /// needs patience, not a tight loop.
    private func scheduleMicReclaim() {
        guard !micRecoveryScheduled, isCapturing, micSignalLost else { return }
        micRecoveryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.micRecoveryScheduled = false
            guard self.isCapturing, self.micSignalLost else { return }
            Self.oslog.log("mic still zeroed — rebuilding the input engine to try to reclaim it")
            self.restartMicCapture()
        }
    }

    // MARK: - Audio File Writing

    private enum AudioStream { case system, mic }

    /// Frames of silence a stream owes before `incoming` frames that arrive
    /// `elapsed` s into the recording, `written` frames already out. The files,
    /// transcript times, diarization and the player all assume both tracks
    /// start at the same instant, but a stream only counts from its first
    /// delivered buffer: the process tap has taken ~5 s to start, a dead tap
    /// rescued by ScreenCaptureKit ~20 s, and a rebuilt mic sends nothing in
    /// between. The first buffer is placed exactly; after that only gaps over
    /// a second count, so callback jitter never nudges a flowing stream.
    static func silenceOwed(elapsed: TimeInterval, written: Int, incoming: Int, sampleRate: Double) -> Int {
        // ponytail: arrival time, not each buffer's host timestamp, so right to
        // within the backend's latency (tens of ms). A backend that stalls, then
        // replays its backlog in a burst, would end up ahead by the stall; pass
        // host times through from the three callbacks if that ever shows up.
        let owed = Int(elapsed * sampleRate) - written - incoming
        let slack = written == 0 ? 0 : Int(sampleRate)
        return owed > slack ? owed : 0
    }

    /// Hands a stream's audio to the two sinks that count samples as time (its
    /// .caf file and transcription), first padding any silence the stream owes
    /// the recording clock. Never to the echo canceller or level meters: a burst
    /// of padding would push the AEC reference seconds out of step with the mic.
    private func emit(_ buffer: AVAudioPCMBuffer, to stream: AudioStream,
                      traceStamp: CapturedAudioClockStamp? = nil, traceEpoch: UUID? = nil) {
        let traceCallbackNs = AnswerAudioTraceRecorder.shared.isEnabled ? AnswerTraceClock.nowNs() : nil
        let source: AudioSource = stream == .system ? .them : .me
        let rate = buffer.format.sampleRate
        var out = stream == .system ? systemFramesOut : micFramesOut
        let elapsed = ProcessInfo.processInfo.systemUptime - captureOrigin
        var owed = Self.silenceOwed(elapsed: elapsed,
                                    written: out, incoming: Int(buffer.frameLength), sampleRate: rate)
        let name = stream == .system ? "system" : "mic"
        let originalOut = out
        if out == 0 {
            Self.oslog.log("first \(name, privacy: .public) buffer \(elapsed, format: .fixed(precision: 3), privacy: .public) s into the recording")
        }
        if owed >= Int(rate / 4) {
            Self.oslog.log("\(name, privacy: .public) audio \(Double(owed) / rate, format: .fixed(precision: 2), privacy: .public) s behind the recording clock — padding silence")
        }
        // One-second pieces: a streaming transcriber gets socket-sized frames.
        while owed > 0, let silence = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                       frameCapacity: AVAudioFrameCount(min(owed, Int(rate)))) {
            silence.frameLength = silence.frameCapacity
            for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                memset(channel.mData, 0, Int(channel.mDataByteSize))
            }
            appendAudio(silence, to: stream)
            onAudioBuffer?(silence, source)
            owed -= Int(silence.frameLength)
            out += Int(silence.frameLength)
        }
        _ = AnswerAudioTraceRecorder.shared.record(sessionID: traceEpoch,
            source: stream == .system ? .them : .me, stamp: traceStamp,
            outputStart: UInt64(out), paddingBefore: UInt64(out - originalOut),
            outputFrames: buffer.frameLength, outputRate: rate, callbackNs: traceCallbackNs)
        appendAudio(buffer, to: stream)
        onAudioBuffer?(buffer, source)
        out += Int(buffer.frameLength)
        if stream == .system { systemFramesOut = out } else { micFramesOut = out }
    }

    /// Appends a PCM buffer to a stream's .caf file off the capture/render thread.
    /// The file is created lazily from the first buffer's own format, so writes can
    /// never fail on a format mismatch and there is no codec to initialize. The
    /// buffer is deep-copied because the audio system reuses it after we return.
    private func appendAudio(_ buffer: AVAudioPCMBuffer, to stream: AudioStream) {
        guard let copy = buffer.deepCopy() else { return }
        let queue = stream == .system ? systemWriteQueue : micWriteQueue
        let url = stream == .system ? systemAudioURL : micAudioURL
        guard let url else { return }

        queue.async { [weak self] in
            guard let self, !self.filesClosed else { return }
            do {
                let file: AVAudioFile
                if stream == .system {
                    if self.systemAudioFile == nil {
                        self.systemAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                    }
                    file = self.systemAudioFile!
                } else {
                    if self.micAudioFile == nil {
                        self.micAudioFile = try AVAudioFile(forWriting: url, settings: copy.format.settings)
                    }
                    file = self.micAudioFile!
                }
                try file.write(from: copy)
            } catch {
                NSLog("Parrot: \(stream) audio write failed — \(error.localizedDescription)")
            }
        }
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer, isMic: Bool = false) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(max(frames, 1))

        // Throttle the main-thread hop per stream: the waveform only needs ~10
        // updates/sec, and dispatching every ~20 ms buffer (×2 streams) thrashed
        // SwiftUI. Sampling at 10 Hz still detects a live mic well within the
        // 15 s dead-mic window.
        let now = Date()
        if isMic {
            guard now.timeIntervalSince(lastMicLevelAt) >= 0.1 else { return }
            lastMicLevelAt = now
        } else {
            guard now.timeIntervalSince(lastSystemLevelAt) >= 0.1 else { return }
            lastSystemLevelAt = now
        }

        DispatchQueue.main.async {
            if isMic {
                self.micLevel = avg
                self.micPeakLevel = max(self.micPeakLevel, avg)
                // Speech sits well above room noise; treat this as "mic is alive".
                if avg > 0.004 {
                    self.lastMicSignalAt = Date()
                    self.micEverHadSignal = true
                }
            } else {
                self.audioLevel = avg
            }
        }
    }

    /// The current system default input or output device (CoreAudio).
    private static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    /// A nonzero default-device ID and AVAudioEngine's advertised format can
    /// exist even when macOS has no actual input device. Check Core Audio's
    /// stream configuration before installing an AVAudioEngine tap; that call
    /// can raise an uncaught Objective-C exception for a phantom input.
    private static func inputChannelCounts(deviceID: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, list) == noErr else {
            return []
        }
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }

    /// The default input's volume slider, 0...1. #98: call apps with
    /// automatic gain control (Discord, Teams) can raise it mid-call, making
    /// the speakers louder in the mic. nil when the device has no slider.
    static func inputVolume() -> Float? {
        guard let deviceID = defaultDeviceID(input: true) else { return nil }
        // Some inputs only put the slider on channel 1, not the main element.
        for element in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(deviceID, &addr),
               AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    /// Name of the current system default input or output device (CoreAudio).
    static func defaultDeviceName(input: Bool) -> String {
        guard let deviceID = defaultDeviceID(input: input) else { return "Unknown" }

        // The property is a CFString reference; fetch it through an Unmanaged
        // slot rather than &CFString (which the compiler rightly flags — taking
        // a raw pointer to an object reference is UB territory).
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let name = nameRef?.takeRetainedValue() else {
            return "Unknown"
        }
        return name as String
    }

    // MARK: - Buffer helpers

    /// Mean absolute sample value — the same "energy" measure the transcription
    /// loop gates on (against its rolling adaptive floor).
    private static func meanAbs(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(into: Float(0)) { $0 += abs($1) } / Float(samples.count)
    }

    /// Mono float samples from a PCM buffer.
    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    /// Mono PCM buffer from float samples in the given format.
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: - Storage

    static func storageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Parrot/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isCapturing else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer for WhisperKit
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer(sampleRate: sampleRate, channels: channels) else {
            return
        }

        var stamp: CapturedAudioClockStamp?
        if AnswerAudioTraceRecorder.shared.isEnabled {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let mapped = (pts.isNumeric && pts.epoch == 0 ? stream.synchronizationClock : nil).map {
                CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock())
            }
            let hostNs = mapped.flatMap { time -> UInt64? in
                guard time.isNumeric, time.epoch == 0, time.value >= 0, time.timescale > 0 else { return nil }
                return AnswerTraceClock.nanoseconds(ticks: UInt64(time.value), numerator: 1_000_000_000,
                                                    denominator: UInt32(time.timescale))
            }
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
            let rawRate = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            stamp = CapturedAudioClockStamp(backend: .screenCapture, hostStartNs: hostNs, hostTicks: nil,
                sourceFrames: frames > 0 && frames <= Int(UInt32.max) ? UInt32(frames) : 0,
                sourceRate: rawRate ?? 0, sourceSampleTime: nil,
                sourceClockValue: pts.value, sourceClockTimescale: pts.timescale)
        }
        let traceEpoch = traceStreamLock.withLock { traceStreamEpochs[ObjectIdentifier(stream)] }
        handleSystemAudio(pcmBuffer, traceStamp: stamp, traceEpoch: traceEpoch)
    }
}

// MARK: - Capture Error

enum CaptureError: LocalizedError {
    case noDisplay
    case noMicrophone
    case screenRecordingDenied
    case systemAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display found for audio capture"
        case .noMicrophone: "No microphone available"
        case .screenRecordingDenied: "Screen Recording permission is required. Please grant it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Parrot."
        case .systemAudioUnavailable: "System audio capture could not start. Allow Parrot in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
        }
    }
}

// MARK: - Buffer Conversion Extensions

extension CMSampleBuffer {
    func toAVAudioPCMBuffer(sampleRate: Double, channels: UInt32) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        ) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, let channelData = pcmBuffer.floatChannelData else { return nil }

        // Copy audio data — handle float32 format
        let byteCount = min(length, Int(pcmBuffer.frameCapacity) * MemoryLayout<Float>.size)
        memcpy(channelData[0], data, byteCount)

        return pcmBuffer
    }
}

extension AVAudioPCMBuffer {
    /// Independent copy of the samples. Tap/conversion buffers are owned by the
    /// audio system and reused on the next callback, so we must copy before
    /// handing the data to an async writer.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
        }
        return copy
    }

    func toCMSampleBuffer(presentationTime: AVAudioTime) -> CMSampleBuffer? {
        let format = self.format
        guard let formatDesc = format.formatDescription as CMFormatDescription? else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameLength), timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMTime(seconds: Double(presentationTime.sampleTime) / format.sampleRate, preferredTimescale: CMTimeScale(format.sampleRate)),
            decodeTimeStamp: .invalid
        )

        guard let data = floatChannelData?[0] else { return nil }
        let dataSize = Int(frameLength) * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let block = blockBuffer else { return nil }
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}

/// `PARROT_AEC_DUMP=1` (#98): the echo canceller's raw mic and the exact
/// reference paired with each frame, as aec-mic_/aec-ref_<ts>.caf next to the
/// recording, so `--aec-replay` can rerun Speex offline on what it saw live.
private final class AECDump {
    private let queue = DispatchQueue(label: "com.uygar.parrot.audio.aecdump")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!
    private var mic: AVAudioFile?
    private var ref: AVAudioFile?

    init?(dir: URL, timestamp: String) {
        guard let mic = try? AVAudioFile(forWriting: dir.appendingPathComponent("aec-mic_\(timestamp).caf"),
                                         settings: format.settings),
              let ref = try? AVAudioFile(forWriting: dir.appendingPathComponent("aec-ref_\(timestamp).caf"),
                                         settings: format.settings) else { return nil }
        self.mic = mic
        self.ref = ref
    }

    /// Mic thread; the writes go to a queue of their own.
    func write(mic m: [Int16], ref r: [Int16]) {
        queue.async { [self] in
            for (file, samples) in [(mic, m), (ref, r)] {
                guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                              frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { continue }
                for (i, x) in samples.enumerated() { channel[i] = Float(x) / 32767 }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try? file.write(from: buffer)
            }
        }
    }

    /// Flushes pending writes; the .caf headers are finalized on release.
    func close() {
        queue.sync { mic = nil; ref = nil }
    }
}
