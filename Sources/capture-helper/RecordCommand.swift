import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

func runRecord(_ config: Config) async throws {
    guard let outputPath = config.outputPath else {
        throw CaptureError.targetRequired("record requires --output PATH")
    }
    guard config.initialWindowId != nil || config.initialPid != nil || !config.initialNames.isEmpty else {
        throw CaptureError.targetRequired("record requires --window-id, --pid, or --window-name")
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    let outputDir = outputURL.deletingLastPathComponent().path
    let fm = FileManager.default
    if !fm.fileExists(atPath: outputDir) {
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }
    if fm.fileExists(atPath: outputPath) {
        try fm.removeItem(at: outputURL)
    }

    let resolved = try await resolveTarget(config)
    let window = resolved.window
    if !resolved.onScreenIds.contains(window.windowID) {
        logErrorMessage(
            code: "offscreen_window_warning",
            message: "selected window is off-screen; recording may produce no frames. Use `capture-helper list --on-screen --capturable --human` for safer targets.",
            context: ["windowId": Int(window.windowID)]
        )
    }
    let srcW = Int(window.frame.width)
    let srcH = Int(window.frame.height)
    let scale = min(Double(config.maxSize) / Double(max(srcW, srcH)), 1.0)
    let outW = max(2, Int(Double(srcW) * scale) & ~1)
    let outH = max(2, Int(Double(srcH) * scale) & ~1)

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let streamConfig = SCStreamConfiguration()
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: config.maxFps)
    streamConfig.width = outW
    streamConfig.height = outH
    streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
    streamConfig.showsCursor = false
    streamConfig.queueDepth = 5

    let delegate = NativeRecordDelegate(
        outputURL: outputURL,
        width: outW,
        height: outH,
        maxFps: config.maxFps
    )
    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)
    let queue = DispatchQueue(label: "record-writer")
    try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: queue)

    logEvent(
        ("type", "record_start"),
        ("engine", "native"),
        ("output", outputPath),
        ("selector", resolved.selector),
        ("windowId", Int(window.windowID)),
        ("width", outW),
        ("height", outH)
    )

    try await stream.startCapture()
    if config.durationSeconds == nil {
        logEvent(("type", "record_waiting"), ("message", "Recording; press Ctrl-C to stop"))
    }
    await waitForRecordStop(duration: config.durationSeconds, delegate: delegate)
    try await stopStream(stream)
    try await delegate.finish()

    let size = (try? fm.attributesOfItem(atPath: outputPath)[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else {
        throw CaptureError.recordFailed("recording produced an empty file: \(outputPath)")
    }

    logEvent(
        ("type", "record_complete"),
        ("engine", "native"),
        ("output", outputPath),
        ("frames", delegate.writtenFrames),
        ("bytes", size)
    )

    if config.openOutput {
        _ = openFile(path: outputPath)
    }
}

private final class NativeRecordDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputURL: URL
    private let maxFps: Int32
    private let minFrameInterval: CMTime
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    private var firstPts: CMTime?
    private var lastWrittenPts: CMTime = .invalid
    private var didStartWriting = false
    private var didFinish = false
    private var frameCount = 0
    private var streamError: Error?
    private var stopHandler: (() -> Void)?
    private let stopLock = NSLock()
    private let latestFrameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

    var writtenFrames: Int { frameCount }

    init(outputURL: URL, width: Int, height: Int, maxFps: Int32) {
        self.outputURL = outputURL
        self.maxFps = maxFps
        self.minFrameInterval = CMTime(value: 1, timescale: maxFps)

        do {
            self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            fatalError("AVAssetWriter setup failed unexpectedly: \(error)")
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 6, 500_000),
                AVVideoMaxKeyFrameIntervalKey: Int(maxFps) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel
            ]
        ]
        self.input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        self.input.expectsMediaDataInRealTime = true

        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        super.init()

        guard writer.canAdd(input) else {
            fatalError("AVAssetWriter cannot add video input")
        }
        writer.add(input)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopLock.lock()
        streamError = error
        let stop = stopHandler
        stopLock.unlock()
        logErrorMessage(code: "stream_stopped", message: "record stream stopped: \(error)")
        stop?()
    }

    func stopOnStreamError(_ handler: @escaping () -> Void) {
        stopLock.lock()
        stopHandler = handler
        let alreadyStopped = streamError != nil
        stopLock.unlock()
        if alreadyStopped {
            handler()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !didFinish else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let copy = copyPixelBuffer(pixelBuffer) {
            latestFrameLock.lock()
            latestPixelBuffer = copy
            latestFrameLock.unlock()
        }

        let sourcePts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPts == nil {
            firstPts = sourcePts
        }
        guard let firstPts else { return }

        let pts = CMTimeSubtract(sourcePts, firstPts)
        if lastWrittenPts.isValid {
            let delta = CMTimeSubtract(pts, lastWrittenPts)
            if delta.isNumeric && CMTimeCompare(delta, minFrameInterval) < 0 {
                return
            }
        }

        if !didStartWriting {
            guard writer.startWriting() else {
                logErrorMessage(code: "record_failed", message: "AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown error")")
                didFinish = true
                return
            }
            writer.startSession(atSourceTime: .zero)
            didStartWriting = true
        }

        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastWrittenPts = pts
            frameCount += 1
            if frameCount == 1 || frameCount % 300 == 0 {
                log("info", "record frames=\(frameCount)")
            }
        } else {
            logErrorMessage(code: "record_failed", message: "failed to append video frame: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    func writeSnapshot(to outputPath: String) throws -> Int {
        latestFrameLock.lock()
        let pixelBuffer = latestPixelBuffer
        latestFrameLock.unlock()
        guard let pixelBuffer else {
            throw CaptureError.snapshotFailed("recording session has not captured a frame yet")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputDir = outputURL.deletingLastPathComponent().path
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputDir) {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: outputPath) {
            try fm.removeItem(at: outputURL)
        }

        let png = try pngDataFromBgraPixelBuffer(pixelBuffer)
        try png.write(to: outputURL, options: .atomic)
        return png.count
    }

    func finish() async throws {
        let error = stopLock.withLock { streamError }
        if let error {
            throw error
        }

        guard didStartWriting else {
            writer.cancelWriting()
            throw CaptureError.recordFailed("recording finished before any frames were captured. The window may be minimized, hidden, offscreen, fully occluded, or not refreshing. Try `capture-helper list --on-screen --human` and select an on-screen window.")
        }
        guard !didFinish else { return }
        didFinish = true
        input.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error {
                    continuation.resume(throwing: CaptureError.recordFailed("AVAssetWriter failed: \(error.localizedDescription)"))
                } else if self.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CaptureError.recordFailed("AVAssetWriter ended with status \(self.writer.status.rawValue)"))
                }
            }
        }
    }
}


private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let format = CVPixelBufferGetPixelFormatType(source)
    var copy: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: format,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &copy) == kCVReturnSuccess,
          let copy else {
        return nil
    }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])
    defer {
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }

    if CVPixelBufferIsPlanar(source) {
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            let bytes = min(srcStride, dstStride)
            for row in 0..<rows {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), bytes)
            }
        }
    } else if let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(copy) {
        let rows = CVPixelBufferGetHeight(source)
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(copy)
        let bytes = min(srcStride, dstStride)
        for row in 0..<rows {
            memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), bytes)
        }
    }
    return copy
}




private func pngDataFromBgraPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws -> Data {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw CaptureError.snapshotFailed("recording session frame has no base address")
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0 else {
        throw CaptureError.snapshotFailed("recording session frame has invalid dimensions")
    }

    var scanlines = Data(capacity: (width * 4 + 1) * height)
    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        scanlines.append(0) // PNG filter type: none
        let row = bytes.advanced(by: y * bytesPerRow)
        for x in 0..<width {
            let pixel = row.advanced(by: x * 4)
            scanlines.append(pixel[2]) // R
            scanlines.append(pixel[1]) // G
            scanlines.append(pixel[0]) // B
            scanlines.append(pixel[3]) // A
        }
    }

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    var ihdr = Data()
    appendBigEndianUInt32(UInt32(width), to: &ihdr)
    appendBigEndianUInt32(UInt32(height), to: &ihdr)
    ihdr.append(8) // bit depth
    ihdr.append(6) // RGBA
    ihdr.append(0) // compression
    ihdr.append(0) // filter
    ihdr.append(0) // interlace
    appendPngChunk(type: "IHDR", payload: ihdr, to: &png)
    appendPngChunk(type: "IDAT", payload: zlibStoredStream(scanlines), to: &png)
    appendPngChunk(type: "IEND", payload: Data(), to: &png)
    return png
}

private func zlibStoredStream(_ payload: Data) -> Data {
    var data = Data([0x78, 0x01]) // zlib header, fastest/no compression
    var offset = 0
    while offset < payload.count {
        let remaining = payload.count - offset
        let length = min(remaining, 65_535)
        data.append(offset + length >= payload.count ? 0x01 : 0x00) // final block + stored block type
        let len = UInt16(length)
        let nlen = ~len
        data.append(UInt8(len & 0xff))
        data.append(UInt8((len >> 8) & 0xff))
        data.append(UInt8(nlen & 0xff))
        data.append(UInt8((nlen >> 8) & 0xff))
        data.append(payload.subdata(in: offset..<(offset + length)))
        offset += length
    }
    appendBigEndianUInt32(adler32(payload), to: &data)
    return data
}

private func appendPngChunk(type: String, payload: Data, to png: inout Data) {
    var typeData = Data(type.utf8)
    appendBigEndianUInt32(UInt32(payload.count), to: &png)
    png.append(typeData)
    png.append(payload)
    typeData.append(payload)
    appendBigEndianUInt32(crc32(typeData), to: &png)
}

private func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
        a = (a + UInt32(byte)) % 65_521
        b = (b + a) % 65_521
    }
    return (b << 16) | a
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >>= 1
            }
        }
    }
    return crc ^ 0xffff_ffff
}

func openFile(path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [path]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        logErrorMessage(code: "open_output_failed", message: "failed to open output: \(error)")
        return false
    }
}

private func stopStream(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        stream.stopCapture { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

private func waitForRecordStop(duration: Double?, delegate: NativeRecordDelegate) async {
    await withCheckedContinuation { continuation in
        final class StopState {
            var didResume = false
            var sources: [DispatchSourceSignal] = []
            var timer: DispatchSourceTimer?
            let lock = NSLock()
        }

        let state = StopState()
        let resumeOnce = {
            state.lock.lock()
            defer { state.lock.unlock() }
            guard !state.didResume else { return }
            state.didResume = true
            for source in state.sources {
                source.cancel()
            }
            state.timer?.cancel()
            continuation.resume()
        }

        let timer: DispatchSourceTimer?
        if let duration {
            let durationTimer = DispatchSource.makeTimerSource(queue: .main)
            durationTimer.schedule(deadline: .now() + duration)
            durationTimer.setEventHandler(handler: resumeOnce)
            timer = durationTimer
        } else {
            timer = nil
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: resumeOnce)
            return source
        }
        state.lock.lock()
        state.sources = sources
        state.timer = timer
        state.lock.unlock()
        for source in sources {
            source.resume()
        }
        timer?.resume()
        delegate.stopOnStreamError(resumeOnce)

        if duration == nil && Runtime.config.framed {
            DispatchQueue.global(qos: .userInitiated).async {
                while let line = readLine() {
                    handleRecordControlLine(line, delegate: delegate, stop: resumeOnce)
                }
                resumeOnce()
            }
        }
    }
}

private func handleRecordControlLine(_ line: String, delegate: NativeRecordDelegate, stop: () -> Void) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    if trimmed == "stop" || trimmed == "quit" || trimmed == "exit" {
        stop()
        return
    }
    if trimmed.hasPrefix("snapshot ") {
        let outputPath = String(trimmed.dropFirst("snapshot ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outputPath.isEmpty else {
            logErrorMessage(code: "snapshot_failed", message: "record session snapshot requires an output path")
            return
        }
        do {
            let bytes = try delegate.writeSnapshot(to: outputPath)
            logEvent(
                ("type", "snapshot"),
                ("engine", "native"),
                ("mode", "record_session"),
                ("output", outputPath),
                ("bytes", bytes)
            )
        } catch {
            logError(error, context: ["output": outputPath])
        }
        return
    }
    logErrorMessage(code: "unknown_command", message: "unknown record session command: \(trimmed)")
}
