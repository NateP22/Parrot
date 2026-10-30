import AppKit
import AVFoundation
import Combine
import CryptoKit
import Darwin
import ScreenCaptureKit
import VideoToolbox

/// Passive evidence for the exact Copilot window. Never captures audio or
/// another app. Own-window pixels alone do NOT prove foreground/unobscured use.
@MainActor final class NativeAnswerFrameRecorder: ObservableObject {
    static let shared = NativeAnswerFrameRecorder()
    nonisolated static var isEnabled: Bool {
        AnswerTraceRecorder.isAllowed(bundleID: Bundle.main.bundleIdentifier,
            flag: Bundle.main.object(forInfoDictionaryKey: "ParrotNativeAnswerTrace"))
    }
    @Published private(set) var status = "QA frames idle"
    private weak var window: NSWindow?
    private var lifecycle=AnswerFrameLifecycle()
    private var sessionID: UUID? { lifecycle.sessionID }
    private var generation: UUID? { lifecycle.generation }
    private var starting: Task<Void,Never>?
    private var stopping: Task<Void,Never>?
    private var stream: FrameStreamOperation?
    private var sink: NativeAnswerFrameSink?
    private var visibilityTimer: Timer?

    func attach(window: NSWindow?) {
        guard Self.isEnabled else { return }
        if window == nil, stream != nil || starting != nil {
            if let sessionID { sink?.trace.noteWriteError(sessionID:sessionID) }
            self.window=nil
            Task { await stop() }
            return
        }
        if let current = self.window, let window, current.windowNumber != window.windowNumber, stream != nil {
            if let sessionID { sink?.trace.noteWriteError(sessionID: sessionID) }
            status = "QA frame target changed"
            Task { await stop() }
            return
        }
        self.window = window
        attemptStart()
    }
    func begin(sessionID: UUID?) {
        guard Self.isEnabled else { return }
        guard let sessionID, stopping == nil, lifecycle.begin(sessionID:sessionID) != nil else {
            status = "QA frame lifecycle unavailable"; return
        }
        status = "QA frames waiting for Copilot window"
        attemptStart()
    }
    private func attemptStart() {
        guard let sessionID, let window, stream == nil, starting == nil else { return }
        guard window.windowNumber > 0, window.windowNumber <= Int(UInt32.max) else { return }
        let windowID = UInt32(window.windowNumber)
        guard let expectedGeneration=generation, lifecycle.start(generation:expectedGeneration) else { return }
        starting = Task { [weak self] in
            guard let self else { return }
            do {
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Parrot/NativeAnswerTrace/" + sessionID.uuidString + "-frames", isDirectory: true)
                try await self.start(windowID: windowID, outputDirectory: root,
                                     sessionID: sessionID, generation: expectedGeneration)
            } catch {
                if self.generation == expectedGeneration, self.lifecycle.phase != .stopping {
                    self.status = "QA frame capture unavailable"
                }
            }
            if self.generation == expectedGeneration { self.starting = nil }
        }
    }
    private static func resourcesReady(at root: URL) -> Bool {
        var parent = root
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            parent.deleteLastPathComponent()
        }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: parent.path),
              let free = attrs[.systemFreeSize] as? NSNumber, free.uint64Value >= 100 * 1024 * 1024 * 1024 else { return false }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return false }
        return (UInt64(stats.free_count)+UInt64(stats.speculative_count))*UInt64(pageSize) >= 2 * 1024 * 1024 * 1024
    }
    private func start(windowID: UInt32, outputDirectory: URL, sessionID: UUID, generation expected: UUID) async throws {
        guard Self.isEnabled, Self.resourcesReady(at: outputDirectory),
              #available(macOS 14.4, *) else { throw CocoaError(.featureUnsupported) }
        // This API only enumerates content available to this process. Names and
        // titles are never read/logged; the exact view-owned window is required.
        let snapshot: FrameContentSnapshot?=await AnswerFrameDeadline.value(seconds:12) { reply in
            SCShareableContent.getCurrentProcessShareableContent { content,_ in
                reply(content.map { FrameContentSnapshot(content:$0) })
            }
        }
        guard let content=snapshot?.content else { throw CocoaError(.userCancelled) }
        try Task.checkCancellation()
        guard generation == expected, self.sessionID == sessionID, lifecycle.phase == .starting,
              let window, UInt32(window.windowNumber) == windowID,
              let target = content.windows.first(where: {
                  AnswerFrameOwner.matches(windowID: $0.windowID, requestedID: windowID,
                      ownerPID: $0.owningApplication?.processID, ownPID: getpid(), onScreen: $0.isOnScreen)
              }), Self.resourcesReady(at: outputDirectory) else { throw CocoaError(.userCancelled) }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = Double(filter.pointPixelScale)
        let size = filter.contentRect.size
        guard scale.isFinite, scale >= 1, scale <= 4, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let width = Int(ceil(Double(size.width)*scale/2))*2
        let height = Int(ceil(Double(size.height)*scale/2))*2
        guard width <= 4096, height <= 4096 else { throw CocoaError(.fileWriteOutOfSpace) }
        let fps=max(60,window.screen?.maximumFramesPerSecond ?? 60)
        guard fps <= 240 else { throw CocoaError(.featureUnsupported) }
        let sink = try NativeAnswerFrameSink(sessionID: sessionID, windowID: windowID,
            root: outputDirectory, width: width, height: height) { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == expected else { return }
                    self.status = "QA frame evidence failed"
                    await self.stop()
                }
            }
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3; config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let capture = SCStream(filter: filter, configuration: config, delegate: sink)
        self.sink=sink // also owned if addStreamOutput fails; Stop finalizes it
        try capture.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        let operation=FrameStreamOperation(capture:capture)
        operation.onConfirmedLateStop={ [weak self] in
            guard let self, self.generation == expected, self.lifecycle.phase == .failedLocked,
                  self.stopping == nil else { return }
            self.stream=nil; self.sink=nil
            _ = self.lifecycle.finishStop(generation:expected,knownStopped:true)
            self.status="QA frames stopped after delayed OS response"
        }
        self.stream=operation
        let started=await operation.start()
        guard started, lifecycle.activate(generation:expected) else {
            let knownStopped=await operation.stop()
            _ = await sink.finish()
            if generation == expected {
                if knownStopped { self.stream=nil; self.sink=nil }
                else {
                    _ = lifecycle.beginStop()
                    _ = lifecycle.finishStop(generation:expected,knownStopped:false)
                }
            }
            throw CocoaError(.userCancelled)
        }
        status = "QA frames starting — baseline not verified"
        sink.setFirstFrameHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == expected, self.lifecycle.phase == .running else { return }
                self.status="QA frames recording — visibility needs review"
            }
        }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, self.generation == expected, let window else { return }
                sink.observeWindow(atNs: AnswerTraceClock.nowNs(), active: NSApp.isActive,
                    key: window.isKeyWindow, visible: window.isVisible,
                    miniaturized: window.isMiniaturized, activeSpace: window.isOnActiveSpace,
                    alpha: Double(window.alphaValue), partlyVisible: window.occlusionState.contains(.visible))
            }
        }
    }
    func stop() async {
        guard Self.isEnabled else { return }
        if let stopping { await stopping.value; return }
        guard let endingGeneration=lifecycle.beginStop() else { return }
        let task=Task { await performStop(generation:endingGeneration) }
        stopping=task
        await task.value
        stopping=nil
    }
    private func performStop(generation expected: UUID) async {
        status="QA frames stopping"
        starting?.cancel()
        let pending = starting
        visibilityTimer?.invalidate(); visibilityTimer = nil
        if let pending { await pending.value }
        if generation == expected { starting=nil }
        let capture=stream,output=sink
        output?.expectStop()
        let knownStopped=await capture?.stop() ?? true
        var verified=false
        if let output {
            verified=await output.finish()
        }
        guard generation == expected else { return }
        if knownStopped { stream=nil; sink=nil }
        _ = lifecycle.finishStop(generation:expected,knownStopped:knownStopped)
        status = knownStopped ? (verified ? "QA movie saved — native review required" : "QA frame evidence failed") :
            "QA capture state unknown — new capture disabled"
    }
}

/// Immutable SDK snapshot transferred to the owner's actor; never mutates UI.
private struct FrameContentSnapshot: @unchecked Sendable { let content: SCShareableContent }

/// One immutable sink/journal per capture; never reused for a later session.
private final class NativeAnswerFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.uygar.parrot.qa.frames", qos: .userInitiated)
    let trace = AnswerFrameTraceRecorder(enabled: true)
    private let sessionID: UUID
    private let root: URL
    private let movieURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var firstNs: UInt64?, lastNs: UInt64?
    private var encodedCount = 0
    private var finished = false
    private var failureReported = false
    private var onFirstRetainedFrame: (@Sendable () -> Void)?
    private let failureHandler: @Sendable () -> Void
    private var visibility: [[String:UInt64]] = []
    private let movieLimit = 1024 * 1024 * 1024

    init(sessionID: UUID, windowID: UInt32, root: URL, width: Int, height: Int,
         failureHandler: @escaping @Sendable () -> Void) throws {
        self.sessionID = sessionID; self.root = root; self.width = width; self.height = height
        self.failureHandler = failureHandler
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions:0o700])
        movieURL = root.appendingPathComponent("own-window.mov")
        writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:AVVideoCodecType.h264, AVVideoWidthKey:width, AVVideoHeightKey:height,
            AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:true],
            AVVideoCompressionPropertiesKey:[AVVideoAllowFrameReorderingKey:false,
                AVVideoAverageBitRateKey:max(1_000_000,width*height*4)]])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = 1_000_000_000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
        super.init()
        guard writer.canAdd(input) else { throw CocoaError(.featureUnsupported) }
        writer.add(input)
        guard writer.startWriting() else { throw CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        trace.start(sessionID: sessionID, windowID: windowID)
    }
    func expectStop() { trace.expectStop(sessionID: sessionID) }
    func setFirstFrameHandler(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if encodedCount > 0 { handler() }
            else { onFirstRetainedFrame=handler }
        }
    }
    func observeWindow(atNs: UInt64?, active: Bool, key: Bool, visible: Bool, miniaturized: Bool,
                       activeSpace: Bool, alpha: Double, partlyVisible: Bool) {
        queue.async { [self] in
            guard !finished else { return }
            guard let atNs, visibility.count < 20_000 else { trace.noteTruncated(sessionID: sessionID); return }
            // Necessary observations only. Partial occlusion visibility does
            // NOT prove full visibility, even for a transparent window.
            visibility.append(["atNs":atNs,"active":active ? 1:0,"key":key ? 1:0,
                "visible":visible ? 1:0,"miniaturized":miniaturized ? 1:0,
                "activeSpace":activeSpace ? 1:0,"opaque":alpha == 1 ? 1:0,"partlyVisible":partlyVisible ? 1:0])
        }
    }
    private func fail() {
        guard !failureReported else { return }
        failureReported=true; failureHandler()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in trace.noteWriteError(sessionID:sessionID); fail() }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { trace.noteWriteError(sessionID: sessionID); return }
        guard !finished, trace.hasCapacity else { trace.noteTruncated(sessionID: sessionID); fail(); return }
        let callbackNs = AnswerTraceClock.nowNs()
        let info = (CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first ?? [:]
        let rawStatus = (info[.status] as? NSNumber)?.intValue
        let status: AnswerFrameStatus
        switch rawStatus.flatMap(SCFrameStatus.init(rawValue:)) {
        case .complete: status = .complete
        case .idle: status = .idle
        case .blank: status = .blank
        case .suspended: status = .suspended
        case .started: status = .started
        case .stopped: status = .stopped
        default: status = .unknown
        }
        let ticks = (info[.displayTime] as? NSNumber)?.uint64Value
        let ns = ticks.flatMap { AnswerTraceClock.nanoseconds(ticks: $0) }
        let rect = (info[.contentRect] as? [String:Any]).flatMap { CGRect(dictionaryRepresentation:$0 as CFDictionary) }
        let pixels = CMSampleBufferGetImageBuffer(buffer)
        var observation = AnswerFrameObservation(status:status,displayTicks:ticks,displayNs:ns,callbackNs:callbackNs,
            rect:rect.map { [Double($0.origin.x),Double($0.origin.y),Double($0.width),Double($0.height)] } ?? [],
            scaleFactor:(info[.scaleFactor] as? NSNumber)?.doubleValue,
            contentScale:(info[.contentScale] as? NSNumber)?.doubleValue,
            pixelWidth:pixels.map(CVPixelBufferGetWidth),pixelHeight:pixels.map(CVPixelBufferGetHeight),
            mediaFrameIndex:nil,mediaPTS:nil)
        if status == .complete, AnswerFrameTraceRecorder.hasCompleteMetadata(observation),
           let ns, let pixels, CVPixelBufferGetWidth(pixels)==width, CVPixelBufferGetHeight(pixels)==height {
            let size = (try? FileManager.default.attributesOfItem(atPath:movieURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size >= movieLimit { trace.noteTruncated(sessionID:sessionID); fail() }
            else if input.isReadyForMoreMediaData, lastNs.map({ns > $0}) ?? true {
                if firstNs == nil { firstNs = ns }
                if let firstNs, ns >= firstNs, ns-firstNs <= UInt64(Int64.max) {
                    let pts = Int64(ns-firstNs)
                    if adaptor.append(pixels,withPresentationTime:CMTime(value:pts,timescale:1_000_000_000)) {
                        observation.mediaFrameIndex=encodedCount; observation.mediaPTS=pts
                        encodedCount += 1; lastNs = ns
                        if encodedCount == 1 { onFirstRetainedFrame?() }
                    }
                }
            }
        }
        let candidate=trace.record(sessionID:sessionID,frame:observation)
        if status == .complete && !candidate { fail() }
        if status == .blank || status == .suspended || status == .unknown { fail() }
    }
    func finish() async -> Bool {
        let shouldFinish = queue.sync { () -> Bool in
            guard !finished else { return false }
            finished=true; trace.stop(); input.markAsFinished(); return true
        }
        guard shouldFinish else { return false }
        let completed: Bool
        if encodedCount == 0 {
            queue.sync { writer.cancelWriting() }
            completed=false
        } else { completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool,Never>) in
            let once = FrameFinishOnce(continuation)
            // Writer/input operations stay on their owning serial queue.
            queue.async { [self] in
                writer.finishWriting { [self] in
                    queue.async { [self] in once.resume(writer.status == .completed) }
                }
            }
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+30) { [weak self] in
                guard let self else { once.resume(false); return }
                queue.async { [self] in
                    if once.resume(false) { self.writer.cancelWriting() }
                }
            }
        } }
        var mediaVerified=false
        if completed { mediaVerified=await verifyMovie() }
        if !mediaVerified { trace.noteWriteError(sessionID:sessionID) }
        do {
            let metadata = try JSONEncoder().encode(trace.snapshot())
            guard metadata.count <= 16*1024*1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            let frameURL = root.appendingPathComponent("frames.json")
            try metadata.write(to:frameURL,options:.withoutOverwriting)
            let windowData = try JSONSerialization.data(withJSONObject:visibility)
            try windowData.write(to:root.appendingPathComponent("window-observations.json"),options:.withoutOverwriting)
            let summary: [String:Any] = ["schema":"qa-own-window-movie-v1","sessionID":sessionID.uuidString,
                "writerCompleted":completed,"containerSamplesAndPTSVerified":mediaVerified,
                "mediaTimeScale":1_000_000_000,"movieFrameCount":encodedCount,
                "movieSHA256":try Self.digestFile(movieURL),
                "metadataSHA256":SHA256.hash(data:metadata).map { String(format:"%02x",$0) }.joined(),
                "decodedLegibilityVerified":false,"independentVisibilityVerified":false,"nativeAcceptance":false]
            let summaryURL=root.appendingPathComponent("SUMMARY.json")
            try JSONSerialization.data(withJSONObject:summary,options:.sortedKeys).write(to:summaryURL,options:.withoutOverwriting)
            for file in [movieURL,frameURL,root.appendingPathComponent("window-observations.json"),summaryURL] {
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
            guard try Data(contentsOf:frameURL)==metadata else { throw CocoaError(.fileReadCorruptFile) }
        } catch { trace.noteWriteError(sessionID:sessionID); return false }
        let final=trace.snapshot()
        return mediaVerified && final.invalidFrames==0 && final.writeErrors==0 && !final.truncated
    }
    private func verifyMovie() async -> Bool {
        do {
            let size=(try FileManager.default.attributesOfItem(atPath:movieURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= movieLimit, encodedCount > 0 else { return false }
            let asset=AVURLAsset(url:movieURL)
            let tracks=try await asset.loadTracks(withMediaType:.video)
            guard tracks.count==1, try await asset.loadTracks(withMediaType:.audio).isEmpty else { return false }
            let natural=try await tracks[0].load(.naturalSize)
            guard natural.width==CGFloat(width),natural.height==CGFloat(height) else { return false }
            let reader=try AVAssetReader(asset:asset)
            let output=AVAssetReaderTrackOutput(track:tracks[0],outputSettings:nil)
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading() else { return false }
            let expected=trace.snapshot().observations.compactMap { $0.mediaPTS }
            var count=0
            while let sample=output.copyNextSampleBuffer() {
                let time=CMSampleBufferGetPresentationTimeStamp(sample)
                guard count<expected.count, CMSampleBufferGetNumSamples(sample)==1,
                      time.isNumeric,time.epoch==0,time.value>=0,time.timescale>0,
                      let ns=AnswerTraceClock.nanoseconds(ticks:UInt64(time.value),numerator:1_000_000_000,
                                                         denominator:UInt32(time.timescale)),
                      ns <= UInt64(Int64.max), abs(Int64(ns)-expected[count])<=1 else { return false }
                count += 1
            }
            return reader.status == .completed && count==expected.count && count==encodedCount
        } catch { return false }
    }
    private static func digestFile(_ url: URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        var hash=SHA256()
        while let bytes=try handle.read(upToCount:1024*1024), !bytes.isEmpty { hash.update(data:bytes) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}

private final class FrameFinishOnce: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Bool,Never>?
    init(_ continuation: CheckedContinuation<Bool,Never>) { self.continuation=continuation }
    @discardableResult func resume(_ value: Bool) -> Bool {
        let ready=lock.withLock { let ready=continuation; continuation=nil; return ready }
        ready?.resume(returning:value)
        return ready != nil
    }
}

/// OS calls have bounded observation deadlines. An unconfirmed stop stays
/// locked out; a late successful start is explicitly stopped again.
@MainActor private final class FrameStreamOperation {
    let capture: SCStream
    private var startInFlight=false
    private var knownStopped=false
    var onConfirmedLateStop: (() -> Void)?
    init(capture: SCStream) { self.capture=capture }
    func start() async -> Bool {
        startInFlight=true; knownStopped=false
        return await withCheckedContinuation { continuation in
            let once=FrameFinishOnce(continuation)
            capture.startCapture { [self] error in
                Task { @MainActor in
                    startInFlight=false
                    let accepted=once.resume(error == nil)
                    if !accepted && error == nil {
                        if await stop() { onConfirmedLateStop?() }
                    }
                }
            }
            Task { try? await Task.sleep(for:.seconds(12)); once.resume(false) }
        }
    }
    func stop() async -> Bool {
        if knownStopped && !startInFlight { return true }
        return await withCheckedContinuation { continuation in
            let once=FrameFinishOnce(continuation)
            capture.stopCapture { [self] error in
                Task { @MainActor in
                    if error == nil && !startInFlight { knownStopped=true }
                    let accepted=once.resume(knownStopped && !startInFlight)
                    if !accepted && knownStopped && !startInFlight { onConfirmedLateStop?() }
                }
            }
            Task { try? await Task.sleep(for:.seconds(12)); once.resume(false) }
        }
    }
}
