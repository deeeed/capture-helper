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
    await waitForRecordStop(duration: config.durationSeconds)
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
        streamError = error
        logErrorMessage(code: "stream_stopped", message: "record stream stopped: \(error)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !didFinish else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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

    func finish() async throws {
        if let streamError {
            throw streamError
        }

        guard didStartWriting else {
            writer.cancelWriting()
            throw CaptureError.recordFailed("recording finished before any frames were captured")
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

private func waitForRecordStop(duration: Double?) async {
    if let duration {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        return
    }

    await withCheckedContinuation { continuation in
        final class StopState {
            var didResume = false
            var sources: [DispatchSourceSignal] = []
        }

        let state = StopState()
        let resumeOnce = {
            guard !state.didResume else { return }
            state.didResume = true
            for source in state.sources {
                source.cancel()
            }
            continuation.resume()
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: resumeOnce)
            state.sources.append(source)
            source.resume()
        }
    }
}
